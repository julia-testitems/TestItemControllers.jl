mutable struct JSONRPCTestItemController
    endpoint::JSONRPC.JSONRPCEndpoint
    test_env_by_id::Dict{String,TestEnvironment}
    controller::TestItemController

    function JSONRPCTestItemController(
        pipe_in,
        pipe_out;
        error_handler_file=nothing,
        crash_reporting_pipename=nothing)

        endpoint = JSONRPC.JSONRPCEndpoint(pipe_in, pipe_out)

        jr = new(endpoint, Dict{String,TestEnvironment}())

        # Helper: send a JSONRPC notification, swallowing transport/endpoint errors.
        # These callbacks run on the reactor thread; if the endpoint has closed
        # (e.g. client disconnected), we must not let the exception propagate
        # because it would interrupt the reactor's handle!() mid-execution and
        # could prevent _check_testrun_complete!() from being reached.
        function _safe_send(args...)
            try
                JSONRPC.send(jr.endpoint, args...)
            catch err
                if err isa JSONRPC.TransportError || err isa JSONRPC.JSONRPCError
                    @debug "JSONRPC callback send failed (endpoint closed?)" exception=(err,)
                else
                    rethrow()
                end
            end
        end

        callbacks = ControllerCallbacks(
            on_testitem_started = (testrun_id, testitem_id, test_env_id) -> _safe_send(
                TestItemControllerProtocol.notficiationTypeTestItemStarted,
                TestItemControllerProtocol.TestItemStartedParams(
                    testRunId=testrun_id,
                    testItemId=testitem_id
                )
            ),
            on_testitem_passed = (testrun_id, testitem_id, test_env_id, duration) -> _safe_send(
                TestItemControllerProtocol.notficiationTypeTestItemPassed,
                TestItemControllerProtocol.TestItemPassedParams(
                    testRunId=testrun_id,
                    testItemId=testitem_id,
                    duration=duration
                )
            ),
            on_testitem_failed = (testrun_id, testitem_id, test_env_id, messages, duration) -> _safe_send(
                TestItemControllerProtocol.notficiationTypeTestItemFailed,
                TestItemControllerProtocol.TestItemFailedParams(
                    testRunId=testrun_id,
                    testItemId=testitem_id,
                    messages=messages,
                    duration=duration
                )
            ),
            on_testitem_errored = (testrun_id, testitem_id, test_env_id, messages, duration) -> _safe_send(
                TestItemControllerProtocol.notficiationTypeTestItemErrored,
                TestItemControllerProtocol.TestItemErroredParams(
                    testRunId=testrun_id,
                    testItemId=testitem_id,
                    messages=messages,
                    duration=duration
                )
            ),
            on_testitem_skipped = (testrun_id, testitem_id, test_env_id) -> _safe_send(
                TestItemControllerProtocol.notficiationTypeTestItemSkipped,
                (testRunId=testrun_id, testItemId=testitem_id)
            ),
            on_append_output = (testrun_id, testitem_id, test_env_id, output) -> _safe_send(
                TestItemControllerProtocol.notficiationTypeAppendOutput,
                TestItemControllerProtocol.AppendOutputParams(
                    testRunId=testrun_id,
                    testItemId=something(testitem_id, missing),
                    output=output
                )
            ),
            on_attach_debugger = (testrun_id, debug_pipename) -> _safe_send(
                TestItemControllerProtocol.notificationTypeLaunchDebugger,
                (;
                    debugPipeName = debug_pipename,
                    testRunId = testrun_id
                )
            ),
            on_process_created = (id, test_env_id) -> begin
                env = get(jr.test_env_by_id, test_env_id, nothing)
                if env !== nothing
                    _safe_send(
                        TestItemControllerProtocol.notificationTypeTestProcessCreated,
                        TestItemControllerProtocol.TestProcessCreatedParams(
                            id = id,
                            packageName = env.package_name,
                            packageUri = env.package_uri,
                            projectUri = something(env.project_uri, missing),
                            coverage = env.mode == "Coverage",
                            env = env.julia_env
                        )
                    )
                end
            end,
            on_process_terminated = id -> _safe_send(
                TestItemControllerProtocol.notificationTypeTestProcessTerminated,
                (;id = id)
            ),
            on_process_status_changed = (id, status) -> _safe_send(
                TestItemControllerProtocol.notificationTypeTestProcessStatusChanged,
                TestItemControllerProtocol.TestProcessStatusChangedParams(id = id, status = status)
            ),
            on_process_output = (id, output) -> _safe_send(
                TestItemControllerProtocol.notificationTypeTestProcessOutput,
                TestItemControllerProtocol.TestProcessOutputParams(id = id, output = output)
            ),
        )

        jr.controller = TestItemController(callbacks; error_handler_file=error_handler_file, crash_reporting_pipename=crash_reporting_pipename)

        return jr
    end
end

function create_testrun_request(params::TestItemControllerProtocol.CreateTestRunParams, jr_controller::JSONRPCTestItemController, token)
    @debug "Received create_testrun request" testrun_id=params.testRunId profile_count=length(params.testProfiles) testitem_count=length(params.testItems) testsetup_count=length(params.testSetups)

    # Convert wire-format TestProfiles into internal TestEnvironment + per-item TestRunItem
    profile = params.testProfiles[1]

    # Group items by package identity and create one TestEnvironment per unique package
    PackageKey = Tuple{String,String,Union{Nothing,String},Union{Nothing,String}}
    envs_by_key = Dict{PackageKey,TestEnvironment}()
    item_env_id = Dict{String,String}()

    for i in params.testItems
        key::PackageKey = (
            coalesce(i.packageName, ""),
            coalesce(i.packageUri, ""),
            coalesce(i.projectUri, nothing),
            coalesce(i.envContentHash, nothing),
        )
        if !haskey(envs_by_key, key)
            env = TestEnvironment(
                string(UUIDs.uuid4()),
                profile.juliaCmd,
                profile.juliaArgs,
                profile.juliaNumThreads,
                profile.juliaEnv,
                profile.mode,
                key[1], key[2], key[3], key[4],
            )
            envs_by_key[key] = env
            jr_controller.test_env_by_id[env.id] = env
        end
        item_env_id[i.id] = envs_by_key[key].id
    end

    test_environments = collect(values(envs_by_key))

    items = [
        TestItemDetail(
            i.id,
            i.uri,
            i.label,
            i.useDefaultUsings,
            i.testSetups,
            i.line,
            i.column,
            i.code,
            i.codeLine,
            i.codeColumn,
        )
        for i in params.testItems
    ]

    work_units = [
        TestRunItem(
            i.id,
            item_env_id[i.id],
            coalesce(i.timeout, nothing),
            jr_controller.controller.log_level
        )
        for i in params.testItems
    ]

    ret = execute_testrun(
        jr_controller.controller,
        params.testRunId,
        test_environments,
        items,
        work_units,
        [
            TestSetupDetail(
                i.packageUri,
                i.name,
                i.kind,
                i.uri,
                i.line,
                i.column,
                i.code
            ) for i in params.testSetups
        ],
        profile.maxProcessCount,
        token;
        coverage_root_uris = coalesce(profile.coverageRootUris, nothing)
    )

    @debug "Finished create_testrun request" testrun_id=params.testRunId coverage_files=ismissing(ret) ? missing : length(ret)
    return TestItemControllerProtocol.CreateTestRunResponse("success", ret)
end

function terminate_test_process_request(params::TestItemControllerProtocol.TerminateTestProcessParams, json_controller::JSONRPCTestItemController, token)
    @debug "Received terminate_test_process request" id=params.testProcessId
    terminate_test_process(json_controller.controller, params.testProcessId)
end

JSONRPC.@message_dispatcher dispatch_msg begin
    TestItemControllerProtocol.create_testrun_request_type => create_testrun_request
    TestItemControllerProtocol.terminate_test_process_request_type => terminate_test_process_request
end

function Base.run(jr_controller::JSONRPCTestItemController)
    @debug "Starting JSON-RPC controller endpoint"
    JSONRPC.start(jr_controller.endpoint)

    @async try
        while true
            msg = JSONRPC.get_next_message(jr_controller.endpoint)
            @debug "Received JSON-RPC message" method=msg.method

            @async try
                @debug "Dispatching JSON-RPC message asynchronously" method=msg.method
                dispatch_msg(jr_controller.endpoint, msg, jr_controller)
            catch err
                bt = catch_backtrace()
                @error "Error dispatching message" exception=(err, bt)
            end
        end
    catch err
        if err isa JSONRPC.TransportError || err isa JSONRPC.JSONRPCError
            @debug "JSONRPC message loop ended" reason=err.msg
        else
            bt = catch_backtrace()
            @error "Error in JSONRPC message loop" exception=(err, bt)
        end
    end

    run(jr_controller.controller)
end

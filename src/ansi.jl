"""
ANSI escape sequence stripping.

Test processes are launched with `--color=yes`, so everything they write — `Test.jl`'s
failure summaries, `Pkg` errors, whatever a test item prints — arrives here carrying
escape sequences. That is deliberate for the sinks that render them (the Test Results
terminal, the per process log views), but any place that folds that text into a plain
context instead — the controller's own log records, JUnit XML — has to take them out
first.
"""

const _ANSI_CSI = r"\e\[[0-9;:<=>?]*[ -/]*[@-~]"
const _ANSI_OSC = r"\e\][^\a\e]*(?:\a|\e\\)"
const _ANSI_OTHER = r"\e[@-Z\\-_]"

function _strip_ansi(s::AbstractString)
    s = replace(s, _ANSI_OSC => "")
    s = replace(s, _ANSI_CSI => "")
    s = replace(s, _ANSI_OTHER => "")
    return s
end

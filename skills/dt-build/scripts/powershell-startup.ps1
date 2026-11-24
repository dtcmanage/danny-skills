# PowerShell's startup JIT profile is shared across concurrent CLI processes. The
# runtime can read a partially rewritten profile and crash before running a script
# (SIGSEGV/139 with empty stdout/stderr on Linux):
# https://github.com/dotnet/runtime/issues/121977
# Set this BEFORE launching children; changing it cannot repair this interpreter's
# already-started JIT. This disables only that optional optimization, not parallelism,
# tiered compilation, module loading, profiles or the worker's execution budget.
function Disable-DtPowerShellStartupProfile {
    $env:DOTNET_MultiCoreJitMinNumCpus = '65535'
    # Also cover PowerShell releases on runtimes that use the legacy prefix.
    $env:COMPlus_MultiCoreJitMinNumCpus = '65535'
}

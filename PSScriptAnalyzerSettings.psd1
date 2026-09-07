@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        # qubixctl is an interactive CLI: progress lines are for the person
        # watching the console, not for a pipeline.  Write-Host is the tool.
        'PSAvoidUsingWriteHost'
    )
}

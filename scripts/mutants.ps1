# Runs the loop tour once per mutant; each must make tests\verify-lab.py fail its target check (see MUTANT_BREAKS).
param([string[]]$Only = @('noanomalysync', 'noguard', 'noanim'), [int]$Seconds = 300)
$results = @()
foreach ($m in $Only) {
    & "$PSScriptRoot\run-tour.ps1" -Mutant $m -Seconds $Seconds | Select-Object -Last 2
    $results += "$m exit=$LASTEXITCODE"
}
$results

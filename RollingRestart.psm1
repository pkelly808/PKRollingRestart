#Requires -Version 3 -Module ActiveDirectory

$ScriptPath = Split-Path $Script:MyInvocation.MyCommand.Path

$Global:Dependencies = "$ScriptPath\Dependencies.txt"
$Global:Transcript = "$ScriptPath\Transcript.txt"

function Get-RRServer {

<#
.SYNOPSIS
.DESCRIPTION
.PARAMETER ComputerName
.EXAMPLE
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName='ByGroup')]
    [ValidateScript({ Get-ADGroup $_ })]
    [String]$Group,

    [Parameter(Mandatory, ParameterSetName='ByComputer')]
    [String[]]$ComputerName,

    [ValidateScript({ Test-Path $_ })]
    [String]$DependenciesFile = $Global:Dependencies
)

    PROCESS {
        if ($PSCmdlet.ParameterSetName -eq 'ByGroup') {
            $ComputerName = (Get-ADGroupMember $Group).Name
        }

        $FileLines = Get-Content $DependenciesFile

        $IndependentArray = @()
        $DependentArray = @()

        Write-Verbose "COMPARE EACH COMPUTER FROM PATCH GROUP WITH DEPENDENCIES FILE"
        foreach ($Computer in $ComputerName) {
            if ($FileLines.Split(',') -contains $Computer) {
                Write-Verbose "Add DependentArray  : $Computer"
                $DependentArray += $Computer
            } else {               
                Write-Verbose "Add IndependentArray: $Computer"
                $IndependentArray += $Computer
            }
        }

        #OUTPUT INDEPENDENT COMPUTERNAME AS STRING
        foreach ($Computer in $IndependentArray) {
            [PSCustomObject]@{
                "ComputerName"=$Computer;
                "Type"="Independent";
            }
        }

        Write-Verbose "COMPARE EACH DEPENDENCIEFILE ROW WITH DEPENDENT ARRAY"
        #For every row within file
        for ($r=0; $r -lt $FileLines.Length; $r++) {

            $RowArray = @()

            #For every column within row
            for ($c=0; $c -lt $FileLines[$r].Split(',').Length; $c++) {
                $FileComputer = $FileLines[$r].Split(',')[$c]
                
                if ($DependentArray -contains $FileComputer) {
                    Write-Verbose "$r,$c; Add RowArray: $FileComputer"
                    $RowArray += $FileComputer
                } else {
                    Write-Verbose "$r,$c; Skip Server : $FileComputer"
                }   
            } #for Column

            #OUTPUT DEPENDENT COMPUTERNAME AS ARRAY
            if ($RowArray) {
                [PSCustomObject]@{
                    "ComputerName"=$RowArray;
                    "Type"="Dependent";
                }
            }

        } #for Row
    } #PROCESS
}


workflow Restart-RRIndependent {
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [String[]]$ComputerName,
    [int]$Sleep = 60,
    [Switch]$Apply
)

    foreach -Parallel ($Computer in $ComputerName) {

        try {

            if ($Apply) { 
                Write-Verbose "Dependent,$Computer,Restarting,$(Get-Date)"

                Restart-Computer -PSComputerName $Computer -Force 
            } else {
                Write-Verbose "Dependent,$Computer,TestRestart,$(Get-Date)"
            }
            
            #Added for additional delay
            Start-Sleep -Seconds $Sleep

        } catch {
            Write-Warning "$Computer,$_"
        }
    }
}

workflow Restart-RRDependent {
<# multidimensional array#>
[CmdletBinding(ConfirmImpact = 'High')]
param(
    #[Parameter(Mandatory,ValueFromPipeline)]
    [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
    [string[]]$ComputerName,
    [int]$Sleep = 60,
    [switch]$Apply
)

    foreach ($Computer in $ComputerName) {
        
        try {

            if ($Apply) { 
                Write-Verbose "Dependent,$Computer,Restarting,$(Get-Date)"

                Restart-Computer -PSComputerName $Computer -Force -Wait
                
                Write-Verbose "Dependent,$Computer,Restarted,$(Get-Date)"
            } else {
                Write-Verbose "Dependent,$Computer,TestRestart,$(Get-Date)"
            }
            
            #Added for additional delay
            Start-Sleep -Seconds $Sleep

        } catch {
            Write-Warning "$Computer,$_"
        }
    }
}


function Get-RRGroup {
[CmdletBinding()]
param(
    [DateTime]$RunDate = (Get-Date)
)

    Write-Verbose "Run Date: $RunDate"

    #First day of the month
    [DateTime]$FirstTuesday = $RunDate.ToString().Replace($RunDate.Day,'1')

    #First Tuesday of the month
    while ($FirstTuesday.DayOfWeek -ine 'Tuesday') {
        $FirstTuesday=$FirstTuesday.AddDays(1)
    }
    Write-Verbose "First Tuesday: $FirstTuesday"
    
    $PatchTuesday = $FirstTuesday.AddDays(7)
    Write-Verbose "Patch Tuesday: $PatchTuesday"

    #Format Date
    [DateTime]$PT = Get-Date -f d ($PatchTuesday)
    [DateTime]$Run = Get-Date -f d ($RunDate)

    #Group based on RunDate relative to Patch Tuesday
    Switch ($Run) {
        ($PT.AddDays(7))  {$Group = "SCCM Server Patch A"}
        ($PT.AddDays(14)) {$Group = "SCCM Server Patch B"}
        ($PT.AddDays(-7)) {$Group = "SCCM Server Patch C"}
        default {$Group = $null; Write-Verbose "No Server Group"}  
    }

    $Group
}


function Use-RollingRestart {
[CmdletBinding(SupportsShouldProcess,ConfirmImpact = 'High')]
param()

    Start-Transcript -Path $Global:Transcript

    #Get group based on date
    $Group = Get-RRGroup -Verbose

    #If no group, do not continue
    if (!$Group) {Write-Warning "No Patch Maintenance Today!"; Stop-Transcript; Return}

    #Get Object (ComputerName, Type) from Group and Dependencies File
    $ds = Get-RRServer -Group $Group

    #Log in transcript in case there is an existing job
    if (Get-Job) {
        Write-Warning 'EXISTING JOBS'
        Get-Job
        Get-Job | Receive-Job
        Get-Job | Remove-Job -Force
    }else {
        Write-Host 'NO EXISTING JOBS'
    }
    
    #Extra for error handling
    if (Get-Job) {Write-Warning 'DID NOT REMOVE JOBS'; Get-Job}

    if ($PSCmdlet.ShouldProcess()) {
        #PROCESS INDEPENDENT COMPUTERS VIA PARALLEL WORKFLOW
        Restart-RRIndependent -ComputerName ($ds | ? Type -eq Independent).ComputerName -AsJob -JobName "Independent" | Out-Null

        #PROCESS DEPENDENT COMPUTER ARRAY VIA SEQUENTIAL WORKFLOW
        $ds | ? Type -eq Dependent | % { Restart-RRDependent -ComputerName $_.ComputerName -AsJob -JobName "$($_.ComputerName[0])" | Out-Null }
    }  

    $i = 0
    #Required to give jobs time to execute
    while (Get-Job) {
        #Break out of loop if run for 1h (30 x 120s)
        $i += 1; if ($i -eq 30) {break}

        Write-Host $i

        Get-Job -State Completed | Receive-Job

        #Workflow Jobs are not removed by Receive-Job; -AutoRemoveJob didn't work either
        Get-Job -HasMoreData $false | Remove-Job

        #Log any jobs that may have errors
        Get-Job | select Name,State | ft -HideTableHeaders

        Start-Sleep -Seconds 120
    }

    if ($i -eq 30) {Write-Warning 'TIMOUT'; Get-Job}

    Stop-Transcript
}

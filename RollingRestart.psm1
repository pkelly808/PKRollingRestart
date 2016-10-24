#Requires -Version 3 -Module ActiveDirectory
#$Global:PKPMDependencies = '\\.psf\home\Documents\Scripts\RollingRestart\Dependencies.txt'
$Global:PKPMDependencies = 'C:\Scripts\RollingRestart\Dependencies.txt'
$Global:PKPMLogs = 'C:\Scripts\RollingRestart\Logs.txt'

function Get-RollingRestart {
<#Version 3 added -Timeout to Restart-Computer#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Get-ADGroup $_ })]
    [String]$Group,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [String]$DependenciesFile
)

    PROCESS {
        $ComputerName = (Get-ADGroupMember $Group).Name
        #$ComputerName = 'LVPKTEST02','LVPKTEST01','SCMGMT'

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
        foreach ($Comp in $IndependentArray) {
            [PSCustomObject][Ordered]@{
                "ComputerName"=$Comp;
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
                [PSCustomObject][Ordered]@{
                    "ComputerName"=$RowArray;
                    "Type"="Dependent";
                }
            }

        } #for Row
    } #PROCESS
}

workflow Restart-PKPMIndependent {
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [String[]]$ComputerName,
    #[int]$Sleep = 60,
    [Switch]$Apply
)

    Write-Host "PROCESS INDEPENDENT COMPUTERS VIA PARALLEL WORKFLOW"
    foreach -Parallel ($Computer in $ComputerName) {

        try {
            Write-Host "Independent,$Computer,Restarting,$(Get-Date)"

            if ($Apply) { Restart-Computer -PSComputerName $Computer -Force }

            #Write-Host "Independent,$Computer,Restarted,$(Get-Date)"

            #Start-Sleep $Sleep
        } catch {
            Write-Warning "$Computer,$_"
        }
    }
}

workflow Restart-PKPMDependent {
<# multidimensional array#>
[CmdletBinding()]
param(
    [Parameter(Mandatory,ValueFromPipeline)]
    [string[]]$ComputerName,
    [int]$Sleep = 60,
    [switch]$Apply
)

    Write-Host "PROCESS DEPENDENT COMPUTER ARRAY VIA SEQUENTIAL WORKFLOW"
    foreach ($Computer in $ComputerName) {
        
        try {
            Write-Host "Dependent,$Computer,Restarting,$(Get-Date)"

            #Switch -Wait will not restart sequential computers until server is up.  Sleep added for additional delay. 
            if ($Apply) { Restart-Computer -PSComputerName $Computer -Force -Wait }
            
            Write-Host "Dependent,$Computer,Restarted,$(Get-Date)"

            Start-Sleep $Sleep
        } catch {
            Write-Warning "$Computer,$_"
        }
    }
}


function Get-PatchGroup {
[CmdletBinding()]
param([DateTime]$RunDate = (Get-Date))

    [int]$NthDay=2
    [string]$WeekDay='Tuesday'

    [DateTime]$StartMonth = $RunDate.ToString().Replace($RunDate.Day,'1')

    while ($StartMonth.DayofWeek -ine $WeekDay ) { $StartMonth=$StartMonth.AddDays(1) }
    
    $PatchTuesday = $StartMonth.AddDays(7*($NthDay-1))

    [DateTime]$PT = Get-Date -f d ($PatchTuesday)
    [DateTime]$Run = Get-Date -f d ($RunDate)

    Switch ($Run) {
        ($PT.AddDays(7))  {$Group = "SCCM Server Patch A"}
        ($PT.AddDays(14)) {$Group = "SCCM Server Patch B"}
        ($PT.AddDays(-7)) {$Group = "SCCM Server Patch C"}
        default {$Group = $null; Write-Verbose "No Patch Maintenance"}  
    }
    Write-Host "PT: $PT; Run: $Run; Group: $Group"

    $Group
}

function Use-RollingRestart {
[CmdletBinding()]
param([Switch]$Apply)

    Start-Transcript -Path $Global:PKPMLogs

    #Get group based on date
    #$Group = Get-PatchGroup -RunDate (Get-Date "10/18/16")
    $Group = Get-PatchGroup

    #If no group, do not continue
    if (!$Group) {Write-Warning "No Patch Maintenance Today!"; Stop-Transcript; Return}

    #Get Object (ComputerName, Type) from Group and Dependencies File
    $ds = Get-RollingRestart -Group $Group -DependenciesFile $Global:PKPMDependencies

    #Log in transcript in case there is an existing job
    if (Get-Job) {
        Write-Warning 'EXISTING JOBS'
        Get-Job
        Get-Job | Receive-Job
        Get-Job | Remove-Job -Force
    }else {
        Write-Host 'NO EXISTING JOBS'
    }

    if (Get-Job) {Write-Warning 'DID NOT REMOVE JOBS'; Get-Job}

    #Restart Independent in parallel via array
    #Restart Dependent sequentially via multidimensional array (each dependency line at a time)
    if ($Apply) {
        Restart-PKPMIndependent -ComputerName ($ds | ? Type -eq Independent).ComputerName -AsJob -JobName "Independent" -Apply | Out-Null
        $ds | ? Type -eq Dependent | % { Restart-PKPMDependent -ComputerName $_.ComputerName -AsJob -JobName "$($_.ComputerName[0])" -Apply | Out-Null }
    } else {
        Restart-PKPMIndependent -ComputerName ($ds | ? Type -eq Independent).ComputerName -AsJob -JobName "Independent" | Out-Null
        $ds | ? Type -eq Dependent | % { Restart-PKPMDependent -ComputerName $_.ComputerName -AsJob -JobName "$($_.ComputerName[0])" | Out-Null }
    }

    $i = 0
    #Required to give jobs time to execute
    while (Get-Job) {
        #break out of loop if run for 1h (30 x 120s)
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


function Register-RollingRestart {
    $Cred = Get-Credential BEACHBODY\run.PSH -Message 'Account used to run Scheduled Task.  Password in Victoria'

    if ($Cred) {
        $Param = @{
            'Action'=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument 'Use-RollingRestart -Apply';
            'Trigger'=New-ScheduledTaskTrigger -Weekly -DaysOfWeek Tue -At 11:45PM;
            'User'=$Cred.UserName;
            'Password'=$Cred.GetNetworkCredential().Password;
            'TaskName'='RollingRestart';
            'Description'='Patch Maintenance Server Restart. -PK Module';
            'RunLevel'='Highest';
        }

        #Force to overwrite existing Scheduled Task
        Register-ScheduledTask @Param -Force
    }
}

function Push-RollingRestart {
    $Servers = 'LVPSH01'

    foreach ($Server in $Servers) {
        $Destination = $PSScriptRoot.Replace("C:","\\$Server\C$")

        if (!(Test-Path $Destination)) { New-Item -Path $Destination -ItemType Directory }

        Copy-Item $PSScriptRoot\* -Destination $Destination
    }
}
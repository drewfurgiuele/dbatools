<#
.SYNOPSIS
This command gets specified SSIS Environment and all its variables

.DESCRIPTION
This command gets Environment from SSIS Catalog. All sensitive valus are decrypted.

.PARAMETER SqlServer
The SQL Server instance.

.PARAMETER Environment
The SSIS Environment name

.PARAMETER Folder
The Folder name that contains the environment

.EXAMPLE
Get-DbaSsisEnvironment -SqlServer localhost -Environment DEV -Folder DWH_ETL

.NOTES
Author: Bartosz Ratajczyk ( @b_ratajczyk )

dbatools PowerShell module (https://dbatools.io)
Copyright (C) 2016 Chrissy LeMaire
This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
You should have received a copy of the GNU General Public License along with this program. If not, see http://www.gnu.org/licenses/.
#>
function Get-DbaSsisEnvironment {

[CmdletBinding(SupportsShouldProcess = $true)]
	Param (
		[parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $True)]
		[Alias("ServerInstance", "SqlInstance", "SqlServers")]
		[object[]]$SqlServer,
		[string]$Environment,
        [string]$Folder
	)

    begin {
        $ISNamespace = "Microsoft.SqlServer.Management.IntegrationServices"

        $connection = Connect-SqlServer -SqlServer $SqlServer

        if ($connection.versionMajor -lt 11)
		{
			throw "SSISDB catalog is only available on Sql Server 2012 and above, exiting... $($connection.versionMajor)"
		}

        try
		{
			Write-Verbose "Connecting to $Source integration services."
			$SSIS = New-Object "$ISNamespace.IntegrationServices" $connection
		}
		catch
		{
			Write-Exception $_
			throw "There was an error connecting to the source integration services."
		}

        $catalog = $SSIS.Catalogs | Where-Object { $_.Name -eq "SSISDB" }
        $folders = $catalog.Folders
    }

    process {
        if($PSCmdlet.ShouldProcess('GetEnvironment')) {
            if ($folder) {
                if ($folders.Name -contains $folder) {
                    $srcFolder = $folders | Where-Object { $_.Name -eq $folder }

                    $srcEnvironment = $srcFolder.Environments | Where-Object {$_.Name -eq $Environment}

                    #encryption handling
                    $encKey = 'MS_Enckey_Env_' + $srcEnvironment.EnvironmentId
                    $encCert = 'MS_Cert_Env_' + $srcEnvironment.EnvironmentId

                    <# SMO does not return sensitive values (gets data from catalog.environment_variables)
                    We have to manualy query internal.environment_variables instead and use symmetric keys
                    within T-SQL code
                    #>

                    $sql = @"
                        OPEN SYMMETRIC KEY $encKey DECRYPTION BY CERTIFICATE $encCert;

                        SELECT
                            ev.variable_id,
                            ev.name,
                            ev.description,
                            ev.type,
                            ev.sensitive,
                            value			= ev.value,
                            ev.sensitive_value,
                            ev.base_data_type,
                            decrypted		= decrypted.value
                        FROM internal.environment_variables ev

                            CROSS APPLY (
                                SELECT
                                    value	= CASE base_data_type
                                                WHEN 'nvarchar' THEN CONVERT(NVARCHAR(MAX), DECRYPTBYKEY(sensitive_value))
                                                WHEN 'bit' THEN CONVERT(NVARCHAR(MAX), CONVERT(bit, DECRYPTBYKEY(sensitive_value)))
                                                WHEN 'datetime' THEN CONVERT(NVARCHAR(MAX), CONVERT(datetime2(0), DECRYPTBYKEY(sensitive_value)))
                                                WHEN 'single' THEN CONVERT(NVARCHAR(MAX), CONVERT(DECIMAL(38, 18), DECRYPTBYKEY(sensitive_value)))
                                                WHEN 'float' THEN CONVERT(NVARCHAR(MAX), CONVERT(DECIMAL(38, 18), DECRYPTBYKEY(sensitive_value)))
                                                WHEN 'decimal' THEN CONVERT(NVARCHAR(MAX), CONVERT(DECIMAL(38, 18), DECRYPTBYKEY(sensitive_value)))
                                                WHEN 'tinyint' THEN CONVERT(NVARCHAR(MAX), CONVERT(tinyint, DECRYPTBYKEY(sensitive_value)))
                                                WHEN 'smallint' THEN CONVERT(NVARCHAR(MAX), CONVERT(smallint, DECRYPTBYKEY(sensitive_value)))
                                                WHEN 'int' THEN CONVERT(NVARCHAR(MAX), CONVERT(INT, DECRYPTBYKEY(sensitive_value)))
                                                WHEN 'bigint' THEN CONVERT(NVARCHAR(MAX), CONVERT(bigint, DECRYPTBYKEY(sensitive_value)))
                                            END
                            ) decrypted

                        WHERE environment_id = $($srcEnvironment.EnvironmentId);

                        CLOSE SYMMETRIC KEY $encKey;
"@

                    $ssisVariables = $connection.Databases['SSISDB'].ExecuteWithResults($sql).Tables[0]
                    
                    foreach($variable in $ssisVariables) {
                        if($variable.sensitive -eq $true) {
                            $value = $variable.decrypted
                        } else {
                            $value = $variable.value
                        }
                        [pscustomobject]@{
                            Id              = $variable.variable_id
                            Name            = $variable.Name
                            Description     = $variable.description
                            Type            = $variable.type
                            IsSensitive     = $variable.sensitive
                            BaseDataType    = $variable.base_data_type
                            Value           = $value
                        }
                    }
                    

                }
            }
        }
    }

    end {

    }

}
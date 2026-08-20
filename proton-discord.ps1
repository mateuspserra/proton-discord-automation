#requires -Version 5.1

# ============================================================
# SOLICITAR PRIVILEGIOS ADMINISTRATIVOS
# ============================================================

$windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

$windowsPrincipal = New-Object `
    Security.Principal.WindowsPrincipal($windowsIdentity)

$isAdministrator = $windowsPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdministrator) {
    Write-Host "Solicitando permissao de administrador..." `
        -ForegroundColor Yellow

    try {
        $currentPowerShell = (Get-Process -Id $PID).Path

        $elevationArguments = (
            '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f
            $PSCommandPath
        )

        $elevatedProcess = Start-Process `
            -FilePath $currentPowerShell `
            -ArgumentList $elevationArguments `
            -Verb RunAs `
            -Wait `
            -PassThru `
            -ErrorAction Stop

        exit $elevatedProcess.ExitCode
    }
    catch {
        Write-Host ""
        Write-Host "Nao foi possivel obter permissao de administrador." `
            -ForegroundColor Red

        Write-Host $_.Exception.Message -ForegroundColor Red

        exit 1
    }
}

$ErrorActionPreference = "Stop"

# Garante suporte a TLS 1.2 em PowerShell 5.1 para requisicoes HTTPS
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
    # Ignora caso ja esteja configurado ou nao suportado
}

# ============================================================
# CONFIGURACOES
# ============================================================

$VpnTimeoutSeconds = 120
$VpnPollSeconds = 3
$DiscordReloadWaitSeconds = 12
$ProtonDisconnectTimeoutSeconds = 30

# ============================================================
# FUNCOES NATIVAS DO WINDOWS
# ============================================================

if (-not ([System.Management.Automation.PSTypeName]"NativeWindow").Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class NativeWindow
{
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@
}

# ============================================================
# LOCALIZAR O PROTON VPN
# ============================================================

function Find-ProtonExe {
    $candidates = @(
        "$env:ProgramFiles\Proton\VPN\ProtonVPN.Launcher.exe",
        "$env:ProgramFiles\Proton\VPN\ProtonVPN.exe",
        "$env:ProgramFiles\Proton Technologies\ProtonVPN\ProtonVPN.exe",
        "${env:ProgramFiles(x86)}\Proton Technologies\ProtonVPN\ProtonVPN.exe",
        "$env:LOCALAPPDATA\Programs\Proton\VPN\ProtonVPN.exe",
        "$env:LOCALAPPDATA\Programs\ProtonVPN\ProtonVPN.exe",
        "$env:LOCALAPPDATA\ProtonVPN\ProtonVPN.exe"
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    # Se nao estiver nos caminhos conhecidos, procura o atalho do Proton VPN no Menu Iniciar
    $startMenuFolders = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    )

    $shortcut = Get-ChildItem -Path $startMenuFolders -Filter "*.lnk" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match "(?i)Proton.*VPN" -or $_.BaseName -match "(?i)ProtonVPN" } |
        Select-Object -First 1

    if ($shortcut) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcutInfo = $shell.CreateShortcut($shortcut.FullName)
        $target = $shortcutInfo.TargetPath

        if (-not [string]::IsNullOrWhiteSpace($target) -and (Test-Path -LiteralPath $target)) {
            return $target
        }
    }

    throw @"
Nao foi possivel localizar o executavel do Proton VPN.

Verifique onde o Proton VPN esta instalado e adicione o caminho
na lista `$candidates, dentro da funcao Find-ProtonExe.
"@
}

# ============================================================
# CONSULTAR O IP PUBLICO
# ============================================================

function Get-PublicIp {
    try {
        $response = Invoke-RestMethod -Uri "https://api.ipify.org?format=json" -TimeoutSec 8 -UseBasicParsing
        if ($response.ip) {
            return ([string]$response.ip).Trim()
        }
    }
    catch {
        # Durante a troca de conexao, e normal a consulta falhar.
    }

    return $null
}

# ============================================================
# VERIFICAR SE EXISTE UMA ROTA DO PROTON VPN
# ============================================================

function Test-ProtonRoute {
    try {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Status -eq "Up" -and
                ("$($_.Name) $($_.InterfaceDescription)" -match "(?i)Proton")
            }

        foreach ($adapter in $adapters) {
            $prefixes = @(
                Get-NetRoute -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty DestinationPrefix
            )

            # Algumas VPNs usam rota padrao.
            $hasDefaultRoute = $prefixes -contains "0.0.0.0/0"

            # Outras usam duas rotas divididas.
            $hasSplitRoutes = ($prefixes -contains "0.0.0.0/1") -and ($prefixes -contains "128.0.0.0/1")

            if ($hasDefaultRoute -or $hasSplitRoutes) {
                return $true
            }
        }
    }
    catch {
        # A mudanca do IP ainda podera confirmar a conexao.
    }

    return $false
}

# ============================================================
# LOCALIZAR E REINICIAR O DISCORD
# ============================================================

function Get-DiscordProcesses {
    return @(
        Get-Process `
            -Name "Discord", "DiscordCanary", "DiscordPTB" `
            -ErrorAction SilentlyContinue
    )
}

function Get-DiscordMainProcess {
    $processes = @(Get-DiscordProcesses)

    return $processes |
        Where-Object {
            $_.MainWindowHandle -ne 0
        } |
        Select-Object -First 1
}

function Reload-Discord {
    $discordProcesses = @(Get-DiscordProcesses)

    if ($discordProcesses.Count -eq 0) {
        throw "O Discord nao esta aberto."
    }

    $mainProcess = $discordProcesses |
        Where-Object {
            $_.MainWindowHandle -ne 0
        } |
        Select-Object -First 1

    if (-not $mainProcess) {
        $mainProcess = $discordProcesses |
            Select-Object -First 1
    }

    $processName = $mainProcess.ProcessName
    $discordExe = $null

    try {
        $discordExe = $mainProcess.Path
    }
    catch {
        $discordExe = $null
    }

    $discordFolder = switch ($processName) {
        "DiscordCanary" {
            "DiscordCanary"
            break
        }

        "DiscordPTB" {
            "DiscordPTB"
            break
        }

        default {
            "Discord"
            break
        }
    }

    $updateExe = Join-Path `
        (Join-Path $env:LOCALAPPDATA $discordFolder) `
        "Update.exe"

    Write-Host (
        "Encerrando {0}..." -f $processName
    ) -ForegroundColor Cyan

    $discordProcesses |
        Stop-Process `
            -Force `
            -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2

    # Garante que processos auxiliares tambem foram encerrados.
    Get-DiscordProcesses |
        Stop-Process `
            -Force `
            -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 1

    Write-Host (
        "Abrindo {0} novamente..." -f $processName
    ) -ForegroundColor Cyan

    if (Test-Path -LiteralPath $updateExe) {
        Start-Process `
            -FilePath $updateExe `
            -ArgumentList "--processStart", "$processName.exe" |
            Out-Null
    }
    elseif (
        -not [string]::IsNullOrWhiteSpace($discordExe) -and
        (Test-Path -LiteralPath $discordExe)
    ) {
        Start-Process `
            -FilePath $discordExe |
            Out-Null
    }
    else {
        throw @"
Nao foi possivel localizar o inicializador do Discord.

Caminho procurado:
$updateExe
"@
    }

    Write-Host (
        "Esperando a janela do Discord reaparecer..."
    ) -ForegroundColor Cyan

    $deadline = (Get-Date).AddSeconds(30)
    $reopenedDiscord = $null

    do {
        Start-Sleep -Seconds 1
        $reopenedDiscord = Get-DiscordMainProcess

        if ($reopenedDiscord) {
            break
        }
    }
    while ((Get-Date) -lt $deadline)

    if (-not $reopenedDiscord) {
        throw (
            "O Discord foi iniciado, mas sua janela nao apareceu."
        )
    }

    Write-Host (
        "Discord reiniciado com sucesso. PID: {0}" -f
        $reopenedDiscord.Id
    ) -ForegroundColor Green

    Write-Host (
        "Aguardando {0} segundos para a reconexao..." -f
        $DiscordReloadWaitSeconds
    ) -ForegroundColor Cyan

    Start-Sleep -Seconds $DiscordReloadWaitSeconds
}

# ============================================================
# DESCONECTAR O PROTON VPN VIA UI AUTOMATION
# ============================================================

function Disconnect-ProtonViaUi {
    param(
        [string]$ProtonExe,
        [int]$TimeoutSeconds = 30
    )

    Write-Host "Localizando a janela do Proton VPN para desconexao..." -ForegroundColor Cyan

    # Carrega assemblies do UI Automation
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    $currentSessionId = (Get-Process -Id $PID).SessionId
    $guiProcessNames = @("ProtonVPN", "ProtonVPN.Client", "ProtonVPN.Launcher", "Proton.VPN.App")

    $getGuiProcesses = {
        @(
            Get-Process -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.SessionId -eq $currentSessionId -and
                    ($guiProcessNames -contains $_.ProcessName -or ($_.ProcessName -match "(?i)^Proton.*VPN" -and $_.ProcessName -notmatch "(?i)Service|WireGuard|OpenVPN"))
                }
        )
    }

    $guiProcesses = & $getGuiProcesses
    $protonWithWindow = $guiProcesses | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1

    # Se a janela estiver na bandeja ou sem MainWindowHandle, reexecuta o launcher para restaurar a janela existente
    if (-not $protonWithWindow -and -not [string]::IsNullOrWhiteSpace($ProtonExe) -and (Test-Path -LiteralPath $ProtonExe)) {
        Write-Host "Restaurando janela do Proton VPN a partir do inicializador..." -ForegroundColor Cyan
        Start-Process -FilePath $ProtonExe | Out-Null
        Start-Sleep -Seconds 2
        $guiProcesses = & $getGuiProcesses
        $protonWithWindow = $guiProcesses | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    }

    if ($protonWithWindow) {
        Write-Host ("Processo selecionado: {0} (PID: {1})" -f $protonWithWindow.ProcessName, $protonWithWindow.Id) -ForegroundColor Cyan
        [NativeWindow]::ShowWindowAsync($protonWithWindow.MainWindowHandle, 9) | Out-Null # SW_RESTORE
        [NativeWindow]::SetForegroundWindow($protonWithWindow.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 500
    }
    elseif ($guiProcesses.Count -gt 0) {
        $firstProc = $guiProcesses | Select-Object -First 1
        Write-Host ("Processo selecionado: {0} (PID: {1})" -f $firstProc.ProcessName, $firstProc.Id) -ForegroundColor Cyan
    }

    # Procura o botao Disconnect / Desconectar via UI Automation
    $disconnectButton = $null
    $buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button
    )

    $searchRoots = @()
    foreach ($proc in $guiProcesses) {
        if ($proc.MainWindowHandle -ne 0) {
            try {
                $winElem = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
                if ($winElem) { $searchRoots += $winElem }
            }
            catch {}
        }
    }

    if ($searchRoots.Count -eq 0) {
        foreach ($proc in $guiProcesses) {
            try {
                $procCondition = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
                    $proc.Id
                )
                $elems = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                    [System.Windows.Automation.TreeScope]::Children,
                    $procCondition
                )
                foreach ($elem in $elems) {
                    $searchRoots += $elem
                }
            }
            catch {}
        }
    }

    foreach ($root in $searchRoots) {
        try {
            $allButtons = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)
            foreach ($btn in $allButtons) {
                $btnName = $btn.Current.Name
                $btnAutomationId = $btn.Current.AutomationId
                if (
                    ($btnName -and ($btnName -match "(?i)^disconnect$" -or $btnName -match "(?i)^desconectar$" -or $btnName -match "(?i)disconnect|desconectar")) -or
                    ($btnAutomationId -and ($btnAutomationId -match "(?i)disconnect|desconectar"))
                ) {
                    $disconnectButton = $btn
                    break
                }
            }
        }
        catch {}

        if ($disconnectButton) { break }
    }

    # Fallback caso nao tenha encontrado nos roots
    if (-not $disconnectButton) {
        foreach ($proc in $guiProcesses) {
            try {
                $procCondition = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
                    $proc.Id
                )
                $andCondition = New-Object System.Windows.Automation.AndCondition($procCondition, $buttonCondition)
                $allButtons = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    $andCondition
                )
                foreach ($btn in $allButtons) {
                    $btnName = $btn.Current.Name
                    $btnAutomationId = $btn.Current.AutomationId
                    if (
                        ($btnName -and ($btnName -match "(?i)disconnect|desconectar")) -or
                        ($btnAutomationId -and ($btnAutomationId -match "(?i)disconnect|desconectar"))
                    ) {
                        $disconnectButton = $btn
                        break
                    }
                }
            }
            catch {}
            if ($disconnectButton) { break }
        }
    }

    if ($disconnectButton) {
        $btnLabel = $disconnectButton.Current.Name
        if ([string]::IsNullOrWhiteSpace($btnLabel)) {
            $btnLabel = $disconnectButton.Current.AutomationId
        }
        Write-Host ("Botao encontrado: '{0}'" -f $btnLabel) -ForegroundColor Green
        Write-Host "Inicio da desconexao da VPN..." -ForegroundColor Cyan

        $invoked = $false
        try {
            $invokePattern = $disconnectButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern) -as [System.Windows.Automation.InvokePattern]
            if ($invokePattern) {
                $invokePattern.Invoke()
                $invoked = $true
            }
        }
        catch {}

        if (-not $invoked) {
            try {
                $togglePattern = $disconnectButton.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern) -as [System.Windows.Automation.TogglePattern]
                if ($togglePattern) {
                    $togglePattern.Toggle()
                    $invoked = $true
                }
            }
            catch {}
        }
    }
    else {
        Write-Warning "Botao Disconnect/Desconectar nao foi localizado via UI Automation."
        return $false
    }

    Write-Host ("Aguardando confirmacao da desconexao (ate {0} segundos)..." -f $TimeoutSeconds) -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $routeRemoved = $false
    $publicIpReturned = $null

    while ((Get-Date) -lt $deadline) {
        $hasProtonRoute = Test-ProtonRoute
        $publicIp = Get-PublicIp

        if (-not $hasProtonRoute) {
            $routeRemoved = $true
        }

        if ($routeRemoved -and (-not [string]::IsNullOrWhiteSpace($publicIp))) {
            $publicIpReturned = $publicIp
            break
        }

        Write-Host "." -NoNewline
        Start-Sleep -Seconds 2
    }

    Write-Host ""

    if (-not $routeRemoved) {
        Write-Warning "A rota da VPN no adaptador Proton ainda permaneceu ativa."
        return $false
    }

    Write-Host "Remocao da rota Proton confirmada." -ForegroundColor Green

    if ([string]::IsNullOrWhiteSpace($publicIpReturned)) {
        Write-Warning "Nao foi possivel acessar a internet comum apos a desconexao."
        return $false
    }

    Write-Host ("Retorno do IP publico confirmado: {0}" -f $publicIpReturned) -ForegroundColor Green
    return $true
}

# ============================================================
# FECHAR A INTERFACE DO PROTON VPN COM SEGURANCA
# ============================================================

function Close-ProtonGuiSafely {
    param(
        [bool]$IsDisconnectedSafely = $false
    )

    if (-not $IsDisconnectedSafely) {
        throw "Encerramento cancelado: a VPN ainda pode estar conectada."
    }

    Write-Host "Fechamento da interface do Proton VPN..." -ForegroundColor Cyan

    $currentSessionId = (Get-Process -Id $PID).SessionId
    $allowedProcessNames = @("ProtonVPN", "ProtonVPN.Client", "ProtonVPN.Launcher", "Proton.VPN.App")

    $guiTargets = @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.SessionId -eq $currentSessionId -and
                ($allowedProcessNames -contains $_.ProcessName -or ($_.ProcessName -match "(?i)^Proton.*VPN" -and $_.ProcessName -notmatch "(?i)Service|WireGuard|OpenVPN"))
            }
    )

    if ($guiTargets.Count -eq 0) {
        Write-Host "Nenhuma interface grafica do Proton VPN aberta na sessao." -ForegroundColor Green
        return
    }

    # Tenta fechar graciosamente com CloseMainWindow
    foreach ($target in $guiTargets) {
        try {
            if ($target.MainWindowHandle -ne 0) {
                $target.CloseMainWindow() | Out-Null
            }
        }
        catch {}
    }

    # Aguarda ate 5 segundos
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        $remaining = @(
            Get-Process -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.SessionId -eq $currentSessionId -and
                    ($allowedProcessNames -contains $_.ProcessName -or ($_.ProcessName -match "(?i)^Proton.*VPN" -and $_.ProcessName -notmatch "(?i)Service|WireGuard|OpenVPN"))
                }
        )
        if ($remaining.Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 500
    }

    # Se ainda restarem processos graficos na sessao do usuario, encerra com Stop-Process -Force
    $remaining = @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.SessionId -eq $currentSessionId -and
                ($allowedProcessNames -contains $_.ProcessName -or ($_.ProcessName -match "(?i)^Proton.*VPN" -and $_.ProcessName -notmatch "(?i)Service|WireGuard|OpenVPN"))
            }
    )

    if ($remaining.Count -gt 0) {
        foreach ($target in $remaining) {
            try {
                Write-Host ("Finalizando interface {0} (PID {1})..." -f $target.ProcessName, $target.Id) -ForegroundColor DarkYellow
                Stop-Process -Id $target.Id -Force -ErrorAction Stop
            }
            catch {
                Write-Warning ("Nao foi possivel finalizar {0}: {1}" -f $target.ProcessName, $_.Exception.Message)
            }
        }
    }

    Write-Host "Interface do Proton VPN fechada com sucesso." -ForegroundColor Green
}

# ============================================================
# EXECUCAO PRINCIPAL
# ============================================================

$completedSuccessfully = $false
$protonDisconnectedSafely = $false

try {
    Write-Host ""
    Write-Host "Automacao Proton VPN + Discord" -ForegroundColor Green
    Write-Host "----------------------------------------"
    Write-Host ""

    $protonExe = Find-ProtonExe

    Write-Host "Proton VPN encontrado em:" -ForegroundColor Cyan
    Write-Host $protonExe
    Write-Host ""

    Write-Host "Consultando o IP publico atual..." -ForegroundColor Cyan

    $ipBefore = Get-PublicIp

    if ($ipBefore) {
        Write-Host "IP antes da VPN: $ipBefore"
    }
    else {
        Write-Host "Nao foi possivel consultar o IP inicial." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Abrindo o Proton VPN..." -ForegroundColor Cyan

    Start-Process -FilePath $protonExe | Out-Null

    Write-Host ("Esperando a VPN conectar por ate {0} segundos..." -f $VpnTimeoutSeconds) -ForegroundColor Cyan

    $deadline = (Get-Date).AddSeconds($VpnTimeoutSeconds)
    $vpnReady = $false
    $ipAfter = $null

    while ((Get-Date) -lt $deadline) {
        $protonRouteReady = Test-ProtonRoute
        $ipAfter = Get-PublicIp

        $ipChanged = -not [string]::IsNullOrWhiteSpace($ipBefore) -and
            -not [string]::IsNullOrWhiteSpace($ipAfter) -and
            $ipAfter -ne $ipBefore

        $routeAndInternetReady = $protonRouteReady -and -not [string]::IsNullOrWhiteSpace($ipAfter)

        if ($ipChanged -or $routeAndInternetReady) {
            $vpnReady = $true
            break
        }

        Write-Host "." -NoNewline
        Start-Sleep -Seconds $VpnPollSeconds
    }

    Write-Host ""
    Write-Host ""

    if (-not $vpnReady) {
        throw ("A conexao da VPN nao foi detectada apos {0} segundos." -f $VpnTimeoutSeconds)
    }

    Write-Host "VPN conectada." -ForegroundColor Green

    if ($ipAfter) {
        Write-Host "IP com VPN: $ipAfter"
    }

    Write-Host ""

    Reload-Discord

    Write-Host ""
    Write-Host "Discord reiniciado com sucesso." -ForegroundColor Green
    Write-Host ""

    # Desconexao controlada via UI Automation
    $protonDisconnectedSafely = Disconnect-ProtonViaUi `
        -ProtonExe $protonExe `
        -TimeoutSeconds $ProtonDisconnectTimeoutSeconds

    if (-not $protonDisconnectedSafely) {
        throw @"
O Proton nao foi desconectado com seguranca.

Verifique se o Advanced Kill Switch esta desativado.
Nenhum processo do Proton foi encerrado.
"@
    }

    Close-ProtonGuiSafely -IsDisconnectedSafely $protonDisconnectedSafely

    $completedSuccessfully = $true
}
catch {
    Write-Host ""
    Write-Host ("ERRO: {0}" -f $_.Exception.Message) -ForegroundColor Red
}
finally {
    Write-Host ""
    # Nunca encerrar o Proton aqui.
    # O finally pode apenas exibir mensagens ou liberar objetos.
}

Write-Host ""

if ($completedSuccessfully) {
    Write-Host "Automacao concluida com sucesso." -ForegroundColor Green
}
else {
    Write-Host "A automacao terminou com erro." -ForegroundColor Red
    exit 1
}

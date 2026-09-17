<#
    Мониторинг скорости линка сетевого адаптера / Network adapter link speed monitor.
    При падении скорости ниже порога (по умолчанию 1 Гбит/с) выполняет
    Restart-NetAdapter (отключение/включение адаптера), чтобы форсировать
    повторное согласование скорости с коммутатором/роутером.

    Язык сообщений в логе определяется автоматически по языку системы:
    русский - если системный язык русский, иначе английский.

    Запускать с правами администратора (Restart-NetAdapter этого требует).

    ---

    Monitors network adapter link speed. If the speed drops below a
    threshold (1 Gbps by default), runs Restart-NetAdapter (disable/enable
    the adapter) to force renegotiation with the switch/router.

    The log message language is detected automatically from the system
    language: Russian if the system language is Russian, English otherwise.

    Run with administrator privileges (required by Restart-NetAdapter).
#>

param(
    # Имя адаптера. Если не указано - будет выбран первый активный Ethernet-адаптер.
    [string]$AdapterName,

    # Как часто проверять скорость, сек.
    [int]$IntervalSeconds = 15,

    # Минимально допустимая скорость, бит/с. 1000000000 = 1 Гбит/с.
    [uint64]$MinSpeedBps = 1000000000,

    # Минимальный интервал между перезапусками адаптера, сек (защита от "дребезга").
    [int]$CooldownSeconds = 90,

    # Если после Restart-NetAdapter скорость всё ещё ниже порога - принудительно
    # выставить "1.0 Gbps Full Duplex" вместо автосогласования.
    [bool]$ForceGigabit = $true,

    # Файл лога.
    [string]$LogPath = (Join-Path $PSScriptRoot "1gbEthernetSpeedMonitor.log"),

    # Таймаут на вызовы Get-NetAdapter/Restart-NetAdapter, сек. Защита от
    # "зависания" WMI-провайдера сетевого адаптера (после серии быстрых
    # перезапусков он иногда перестаёт отвечать, и вызов без таймаута
    # мог бы заблокировать цикл мониторинга навсегда без единой записи в лог).
    [int]$CmdletTimeoutSeconds = 20
)

# Определение языка системы: русский - если язык интерфейса ОС русский,
# иначе используется английский.
$Lang = if ((Get-UICulture).TwoLetterISOLanguageName -eq 'ru') { 'ru' } else { 'en' }

$Messages = @{
    ru = @{
        NotAdmin              = "Скрипт нужно запускать с правами администратора (требуется для Restart-NetAdapter). Завершение."
        NoActiveAdapter       = "Не найден активный физический Ethernet-адаптер. Укажите его явно через -AdapterName."
        AvailableAdapters     = "Доступные адаптеры:"
        AutoDetectedAdapter   = "Автоматически определён адаптер '{0}' (текущая скорость: {1})."
        AdapterLine           = "  {0} - {1} - {2}"
        StartMonitoring       = "Старт мониторинга адаптера '{0}'. Порог: {1} Гбит/с. Интервал проверки: {2} сек. Cooldown перезапуска: {3} сек."
        AdapterNotUp          = "Адаптер '{0}' не в состоянии Up (текущее: {1}) - пропуск проверки скорости."
        SpeedDrop             = "Падение скорости: {0} (ниже порога {1} Гбит/с)."
        TimeSinceResume       = "С последнего выхода системы из сна прошло {0} сек."
        CooldownSkip          = "Перезапуск пропущен (cooldown), ещё {0} сек до следующей попытки."
        RestartingAdapter     = "Выполняю Restart-NetAdapter для '{0}'..."
        AfterRestart          = "После перезапуска: скорость {0}, статус {1}."
        StillBelowThreshold   = "Скорость всё ещё ниже порога - принудительно фиксирую 1.0 Gbps Full Duplex вместо автосогласования."
        AfterForcedSet        = "После принудительной установки: скорость {0}, статус {1}."
        RestartError          = "Ошибка при Restart-NetAdapter: {0}"
        PollError             = "Ошибка при опросе адаптера '{0}': {1}"
        CmdletTimeout         = "Команда не ответила за {0} сек (похоже, завис сетевой провайдер) - прерываю и повторю попытку на следующей итерации."
        NoSpeedDuplexProperty = "У адаптера '{0}' не найдено свойство 'Speed & Duplex' - драйвер не поддерживает принудительную установку скорости."
        NoNonAutoValues       = "У свойства '{0}' нет значений, кроме автосогласования - принудительная установка невозможна."
        AlreadyMax            = "Свойство '{0}' уже установлено в максимальное значение '{1}' - принудительная установка не требуется."
        ForcedSet             = "Принудительно установлено '{0}' = '{1}' (код {2}) для адаптера '{3}'."
        ForceSetFailed        = "Не удалось установить '{0}': {1}"
    }
    en = @{
        NotAdmin              = "This script must be run with administrator privileges (required by Restart-NetAdapter). Exiting."
        NoActiveAdapter       = "No active physical Ethernet adapter found. Specify one explicitly via -AdapterName."
        AvailableAdapters     = "Available adapters:"
        AutoDetectedAdapter   = "Auto-detected adapter '{0}' (current speed: {1})."
        AdapterLine           = "  {0} - {1} - {2}"
        StartMonitoring       = "Starting monitoring of adapter '{0}'. Threshold: {1} Gbps. Check interval: {2} sec. Restart cooldown: {3} sec."
        AdapterNotUp          = "Adapter '{0}' is not in the Up state (current: {1}) - skipping speed check."
        SpeedDrop             = "Speed drop detected: {0} (below threshold {1} Gbps)."
        TimeSinceResume       = "{0} sec have passed since the system last resumed from sleep."
        CooldownSkip          = "Restart skipped (cooldown), {0} sec left until the next attempt."
        RestartingAdapter     = "Running Restart-NetAdapter for '{0}'..."
        AfterRestart          = "After restart: speed {0}, status {1}."
        StillBelowThreshold   = "Speed is still below the threshold - forcing 1.0 Gbps Full Duplex instead of auto-negotiation."
        AfterForcedSet        = "After forced setting: speed {0}, status {1}."
        RestartError          = "Error during Restart-NetAdapter: {0}"
        PollError             = "Error polling adapter '{0}': {1}"
        CmdletTimeout         = "Command did not respond within {0} sec (the network provider appears to be stuck) - aborting and will retry on the next iteration."
        NoSpeedDuplexProperty = "Adapter '{0}' has no 'Speed & Duplex' property - the driver does not support forcing the speed."
        NoNonAutoValues       = "Property '{0}' has no values other than auto-negotiation - forcing is not possible."
        AlreadyMax            = "Property '{0}' is already set to the maximum value '{1}' - forcing is not required."
        ForcedSet             = "Forced '{0}' = '{1}' (code {2}) for adapter '{3}'."
        ForceSetFailed        = "Failed to set '{0}': {1}"
    }
}

function Get-Msg {
    param(
        [string]$Key,
        [object[]]$FormatArgs = @()
    )
    $template = $Messages[$Lang][$Key]
    if ($FormatArgs.Count -gt 0) {
        return ($template -f $FormatArgs)
    }
    return $template
}

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

function Invoke-WithTimeout {
    # Выполняет $ScriptBlock в отдельном runspace и ждёт не дольше $TimeoutSeconds.
    # Нужно потому, что Get-NetAdapter/Restart-NetAdapter обращаются к
    # WMI-провайдеру сетевого адаптера, а тот иногда перестаёт отвечать
    # после серии быстрых перезапусков адаптера - обычный вызов в этом
    # случае блокируется навсегда без исключения, и цикл мониторинга
    # молча "зависает" без единой новой записи в логе.
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = $CmdletTimeoutSeconds
    )
    $ps = [PowerShell]::Create()
    try {
        $ps.AddScript($ScriptBlock) | Out-Null
        foreach ($arg in $ArgumentList) { $ps.AddArgument($arg) | Out-Null }
        $asyncResult = $ps.BeginInvoke()
        if (-not $asyncResult.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            $ps.Stop() | Out-Null
            throw (Get-Msg 'CmdletTimeout' @($TimeoutSeconds))
        }
        return $ps.EndInvoke($asyncResult)
    }
    finally {
        $ps.Dispose()
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-ForcedGigabitSpeed {
    param([string]$AdapterName)

    # Стандартный NDIS-ключ "Speed & Duplex" почти у всех вендоров называется *SpeedDuplex.
    # Работаем через RegistryValue/RegistryKeyword, а не DisplayValue/DisplayName -
    # текстовые значения локализованы (у Realtek, например, "1 Гбит/с дуплекс"),
    # а числовые коды одинаковы независимо от языка системы.
    $prop = Get-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword "*SpeedDuplex" -ErrorAction SilentlyContinue

    if (-not $prop) {
        # Фолбэк для драйверов с нестандартным ключом - ищем по названию ключа реестра.
        $prop = Get-NetAdapterAdvancedProperty -Name $AdapterName -AllProperties -ErrorAction SilentlyContinue |
            Where-Object { $_.RegistryKeyword -match 'SpeedDuplex' } |
            Select-Object -First 1
    }

    if (-not $prop -or -not $prop.ValidRegistryValues) {
        Write-Log (Get-Msg 'NoSpeedDuplexProperty' @($AdapterName))
        return $false
    }

    # "0" почти всегда означает "Автосогласование". Берём максимальный ненулевой
    # код - по конвенции драйверов он соответствует наивысшей доступной скорости/дуплексу.
    $registryValues = $prop.ValidRegistryValues | ForEach-Object { [int]$_ }
    $numericValues = $registryValues | Where-Object { $_ -ne 0 }

    if (-not $numericValues) {
        Write-Log (Get-Msg 'NoNonAutoValues' @($prop.DisplayName))
        return $false
    }

    $targetValue = ($numericValues | Measure-Object -Maximum).Maximum
    $targetIndex = [array]::IndexOf($registryValues, $targetValue)
    $targetDisplay = if ($targetIndex -ge 0) { $prop.ValidDisplayValues[$targetIndex] } else { "код $targetValue" }

    if ([int]$prop.RegistryValue[0] -eq $targetValue) {
        Write-Log (Get-Msg 'AlreadyMax' @($prop.DisplayName, $targetDisplay))
        return $false
    }

    try {
        Set-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword $prop.RegistryKeyword -RegistryValue $targetValue -ErrorAction Stop
        Write-Log (Get-Msg 'ForcedSet' @($prop.DisplayName, $targetDisplay, $targetValue, $AdapterName))
        return $true
    }
    catch {
        Write-Log (Get-Msg 'ForceSetFailed' @($prop.DisplayName, $_.Exception.Message))
        return $false
    }
}

function Get-SecondsSinceLastResume {
    # Событие 107 (Kernel-Power) - "система вышла из сна". Помогает понять,
    # не совпадает ли падение скорости с пробуждением компьютера.
    $lastResume = Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 107 } -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($lastResume) {
        return [int]((Get-Date) - $lastResume.TimeCreated).TotalSeconds
    }
    return $null
}

if (-not (Test-IsAdministrator)) {
    Write-Warning (Get-Msg 'NotAdmin')
    exit 1
}

# Автоопределение адаптера, если имя не задано явно.
# PhysicalMediaType = '802.3' - это признак именно проводного Ethernet
# (в отличие от '-notmatch 802.11', он надёжно исключает не только Wi-Fi,
# но и Bluetooth PAN, мобильные модемы и прочие не-Ethernet среды).
# Среди подходящих адаптеров выбираем тот, у кого сейчас самая высокая
# согласованная скорость линка - как правило, это и есть "правильный"
# рабочий Ethernet-адаптер, а не второстепенный/неподключенный порт.
if (-not $AdapterName) {
    $candidates = Get-NetAdapter |
        Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false -and $_.PhysicalMediaType -eq '802.3' } |
        Sort-Object -Property Speed, ifIndex -Descending

    $candidate = $candidates | Select-Object -First 1

    if (-not $candidate) {
        Write-Log (Get-Msg 'NoActiveAdapter')
        Write-Log (Get-Msg 'AvailableAdapters')
        Get-NetAdapter | ForEach-Object { Write-Log (Get-Msg 'AdapterLine' @($_.Name, $_.Status, $_.LinkSpeed)) }
        exit 1
    }
    $AdapterName = $candidate.Name
    Write-Log (Get-Msg 'AutoDetectedAdapter' @($AdapterName, $candidate.LinkSpeed))
}

$thresholdGbps = [math]::Round($MinSpeedBps / 1e9, 2)
Write-Log (Get-Msg 'StartMonitoring' @($AdapterName, $thresholdGbps, $IntervalSeconds, $CooldownSeconds))

$lastResetTime = [datetime]::MinValue

while ($true) {
    try {
        $nic = Invoke-WithTimeout -ScriptBlock { param($Name) Get-NetAdapter -Name $Name -ErrorAction Stop } -ArgumentList @($AdapterName) |
            Select-Object -First 1

        if ($nic.Status -ne 'Up') {
            Write-Log (Get-Msg 'AdapterNotUp' @($AdapterName, $nic.Status))
        }
        else {
            $speedBps = [uint64]$nic.Speed
            $speedText = $nic.LinkSpeed

            if ($speedBps -gt 0 -and $speedBps -lt $MinSpeedBps) {
                Write-Log (Get-Msg 'SpeedDrop' @($speedText, $thresholdGbps))

                $secondsSinceResume = Get-SecondsSinceLastResume
                if ($null -ne $secondsSinceResume) {
                    Write-Log (Get-Msg 'TimeSinceResume' @($secondsSinceResume))
                }

                $secondsSinceReset = ((Get-Date) - $lastResetTime).TotalSeconds
                if ($secondsSinceReset -lt $CooldownSeconds) {
                    $wait = [int]($CooldownSeconds - $secondsSinceReset)
                    Write-Log (Get-Msg 'CooldownSkip' @($wait))
                }
                else {
                    Write-Log (Get-Msg 'RestartingAdapter' @($AdapterName))
                    try {
                        Invoke-WithTimeout -ScriptBlock { param($Name) Restart-NetAdapter -Name $Name -Confirm:$false -ErrorAction Stop } -ArgumentList @($AdapterName) | Out-Null
                        $lastResetTime = Get-Date
                        Start-Sleep -Seconds 5
                        $nicAfter = Invoke-WithTimeout -ScriptBlock { param($Name) Get-NetAdapter -Name $Name } -ArgumentList @($AdapterName) |
                            Select-Object -First 1
                        Write-Log (Get-Msg 'AfterRestart' @($nicAfter.LinkSpeed, $nicAfter.Status))

                        if ($ForceGigabit -and [uint64]$nicAfter.Speed -lt $MinSpeedBps) {
                            Write-Log (Get-Msg 'StillBelowThreshold')
                            if (Set-ForcedGigabitSpeed -AdapterName $AdapterName) {
                                Start-Sleep -Seconds 5
                                $nicForced = Invoke-WithTimeout -ScriptBlock { param($Name) Get-NetAdapter -Name $Name } -ArgumentList @($AdapterName) |
                                    Select-Object -First 1
                                Write-Log (Get-Msg 'AfterForcedSet' @($nicForced.LinkSpeed, $nicForced.Status))
                            }
                        }
                    }
                    catch {
                        Write-Log (Get-Msg 'RestartError' @($_.Exception.Message))
                    }
                }
            }
        }
    }
    catch {
        Write-Log (Get-Msg 'PollError' @($AdapterName, $_.Exception.Message))
    }

    Start-Sleep -Seconds $IntervalSeconds
}

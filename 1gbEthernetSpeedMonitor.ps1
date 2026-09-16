<#
    Мониторинг скорости линка сетевого адаптера.
    При падении скорости ниже порога (по умолчанию 1 Гбит/с) выполняет
    Restart-NetAdapter (отключение/включение адаптера), чтобы форсировать
    повторное согласование скорости с коммутатором/роутером.

    Запускать с правами администратора (Restart-NetAdapter этого требует).
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
    [string]$LogPath = (Join-Path $PSScriptRoot "1gbEthernetSpeedMonitor.log")
)

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
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
        Write-Log "У адаптера '$AdapterName' не найдено свойство 'Speed & Duplex' - драйвер не поддерживает принудительную установку скорости."
        return $false
    }

    # "0" почти всегда означает "Автосогласование". Берём максимальный ненулевой
    # код - по конвенции драйверов он соответствует наивысшей доступной скорости/дуплексу.
    $registryValues = $prop.ValidRegistryValues | ForEach-Object { [int]$_ }
    $numericValues = $registryValues | Where-Object { $_ -ne 0 }

    if (-not $numericValues) {
        Write-Log "У свойства '$($prop.DisplayName)' нет значений, кроме автосогласования - принудительная установка невозможна."
        return $false
    }

    $targetValue = ($numericValues | Measure-Object -Maximum).Maximum
    $targetIndex = [array]::IndexOf($registryValues, $targetValue)
    $targetDisplay = if ($targetIndex -ge 0) { $prop.ValidDisplayValues[$targetIndex] } else { "код $targetValue" }

    if ([int]$prop.RegistryValue[0] -eq $targetValue) {
        Write-Log "Свойство '$($prop.DisplayName)' уже установлено в максимальное значение '$targetDisplay' - принудительная установка не требуется."
        return $false
    }

    try {
        Set-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword $prop.RegistryKeyword -RegistryValue $targetValue -ErrorAction Stop
        Write-Log "Принудительно установлено '$($prop.DisplayName)' = '$targetDisplay' (код $targetValue) для адаптера '$AdapterName'."
        return $true
    }
    catch {
        Write-Log "Не удалось установить '$($prop.DisplayName)': $($_.Exception.Message)"
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
    Write-Warning "Скрипт нужно запускать с правами администратора (требуется для Restart-NetAdapter). Завершение."
    exit 1
}

# Автоопределение адаптера, если имя не задано явно.
if (-not $AdapterName) {
    $candidate = Get-NetAdapter |
        Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false -and $_.PhysicalMediaType -notmatch '802\.11' } |
        Sort-Object -Property ifIndex |
        Select-Object -First 1

    if (-not $candidate) {
        Write-Log "Не найден активный физический Ethernet-адаптер. Укажите его явно через -AdapterName."
        Write-Log "Доступные адаптеры:"
        Get-NetAdapter | ForEach-Object { Write-Log ("  {0} - {1} - {2}" -f $_.Name, $_.Status, $_.LinkSpeed) }
        exit 1
    }
    $AdapterName = $candidate.Name
}

$thresholdGbps = [math]::Round($MinSpeedBps / 1e9, 2)
Write-Log "Старт мониторинга адаптера '$AdapterName'. Порог: $thresholdGbps Гбит/с. Интервал проверки: $IntervalSeconds сек. Cooldown перезапуска: $CooldownSeconds сек."

$lastResetTime = [datetime]::MinValue

while ($true) {
    try {
        $nic = Get-NetAdapter -Name $AdapterName -ErrorAction Stop

        if ($nic.Status -ne 'Up') {
            Write-Log "Адаптер '$AdapterName' не в состоянии Up (текущее: $($nic.Status)) - пропуск проверки скорости."
        }
        else {
            $speedBps = [uint64]$nic.Speed
            $speedText = $nic.LinkSpeed

            if ($speedBps -gt 0 -and $speedBps -lt $MinSpeedBps) {
                Write-Log "Падение скорости: $speedText (ниже порога $thresholdGbps Гбит/с)."

                $secondsSinceResume = Get-SecondsSinceLastResume
                if ($null -ne $secondsSinceResume) {
                    Write-Log "С последнего выхода системы из сна прошло $secondsSinceResume сек."
                }

                $secondsSinceReset = ((Get-Date) - $lastResetTime).TotalSeconds
                if ($secondsSinceReset -lt $CooldownSeconds) {
                    $wait = [int]($CooldownSeconds - $secondsSinceReset)
                    Write-Log "Перезапуск пропущен (cooldown), ещё $wait сек до следующей попытки."
                }
                else {
                    Write-Log "Выполняю Restart-NetAdapter для '$AdapterName'..."
                    try {
                        Restart-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop
                        $lastResetTime = Get-Date
                        Start-Sleep -Seconds 5
                        $nicAfter = Get-NetAdapter -Name $AdapterName
                        Write-Log "После перезапуска: скорость $($nicAfter.LinkSpeed), статус $($nicAfter.Status)."

                        if ($ForceGigabit -and [uint64]$nicAfter.Speed -lt $MinSpeedBps) {
                            Write-Log "Скорость всё ещё ниже порога - принудительно фиксирую 1.0 Gbps Full Duplex вместо автосогласования."
                            if (Set-ForcedGigabitSpeed -AdapterName $AdapterName) {
                                Start-Sleep -Seconds 5
                                $nicForced = Get-NetAdapter -Name $AdapterName
                                Write-Log "После принудительной установки: скорость $($nicForced.LinkSpeed), статус $($nicForced.Status)."
                            }
                        }
                    }
                    catch {
                        Write-Log "Ошибка при Restart-NetAdapter: $($_.Exception.Message)"
                    }
                }
            }
        }
    }
    catch {
        Write-Log "Ошибка при опросе адаптера '$AdapterName': $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $IntervalSeconds
}


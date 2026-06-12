'use strict';
'require baseclass';

// vpnpool in-app i18n — AUTOMATIC, follows the system/browser language only
// (ru* -> Russian, else English). No manual switch. Translates view content via
// tr() and forces the menu tab labels to match (LuCI's global language would
// otherwise translate common words inconsistently). No MutationObserver — tabs
// are translated a few times right after load to avoid flicker on content updates.
// Must return a CLASS (baseclass.extend); LuCI instantiates it as a singleton.

var DICT = {
	ru: {
		'Save': 'Сохранить', 'Remove': 'Удалить', 'Add source': 'Добавить источник',
		'Add node': 'Добавить узел', 'Use': 'Выбрать', 'Refresh': 'Обновить',
		'Update now': 'Обновить сейчас', 'Please wait': 'Подождите…',
		'unknown': 'неизвестно', 'days': 'дн.', 'expired': 'истекла', 'down': 'недоступен',
		'Dashboard': 'Дашборд', 'Sources': 'Источники', 'Routing': 'Маршрутизация',
		'Settings': 'Настройки', 'Diagnostics': 'Диагностика',
		'VPN Pool — Dashboard': 'VPN Pool — Дашборд', 'Nodes': 'Узлы',
		'Starting…': 'Запуск…', 'Stopping…': 'Остановка…',
		'Switched to %s': 'Переключено на %s', 'Updating subscription…': 'Обновляю подписку…',
		'Pinging all nodes…': 'Пингую все узлы…', 'running': 'работает', 'stopped': 'выключено',
		'routing up': 'маршрутизация активна', 'no routing': 'без маршрутизации',
		'all except lists': 'всё кроме списков', 'only lists': 'только списки',
		'Turn OFF': 'Выключить', 'Turn ON': 'Включить', 'Active node': 'Активный узел',
		'auto / urltest': 'авто / urltest', 'Subscription': 'Подписка', 'expires %s': 'истекает %s',
		'Service is stopped — start it to see live node pings.': 'Служба выключена — включите, чтобы видеть пинги узлов.',
		'No nodes yet (waiting for subscription / pings)…': 'Пока нет узлов (ждём подписку / пинги)…',
		'Node': 'Узел', 'Server': 'Сервер', 'Ping': 'Пинг', 'Select': 'Выбор',
		'AUTO (urltest)': 'АВТО (urltest)', 'auto-ping + failover': 'авто-пинг + переключение',
		'Ping all nodes': 'Пинговать все узлы',
		'Configure': 'Настроить', 'Cancel': 'Отмена', 'pool': 'пул', 'all nodes': 'все узлы', 'manual': 'вручную',
		'Configure auto-switch pool': 'Настроить пул авто-переключения',
		'Auto-switch pool': 'Пул авто-переключения', 'Auto-switch pool saved.': 'Пул авто-переключения сохранён.',
		'Select which nodes take part in automatic switching (urltest). Unchecked nodes stay available for manual selection only.':
			'Выберите узлы, участвующие в авто-переключении (urltest). Невыбранные останутся доступны только для ручного выбора.',
		'Select at least one node for auto-switching.': 'Выберите хотя бы один узел для авто-переключения.',
		'Excluded from auto-switching (manual only)': 'Не участвует в авто-переключении (только вручную)',
		'Saved from subscription (kept after it expires)': 'Сохранён из подписки (остаётся после её окончания)',
		'saved': 'сохранён', 'activated': 'активирован', 'Add to active': 'В активные', 'Actions': 'Действия',
		'A saved node you promoted into the active pool': 'Сохранённый узел, добавленный в активный пул',
		'Remove from the active pool (keeps it saved)': 'Убрать из активного пула (останется сохранённым)',
		'Add this saved node to the active pool': 'Добавить этот сохранённый узел в активный пул',
		'Saved from subscription (inactive)': 'Сохранённые из подписки (неактивные)',
		'Saved nodes are kept here even after the subscription drops them. They are NOT in the active pool until you add them.':
			'Сохранённые узлы остаются здесь даже после того, как подписка их убрала. В активный пул они не входят, пока вы их не добавите.',
		'No inactive saved nodes. Star a node to keep it here after the subscription drops it.':
			'Нет неактивных сохранённых узлов. Отметьте узел звездой ⭐, чтобы он остался здесь после исчезновения из подписки.',
		'Added to the active pool: %s': 'Добавлен в активный пул: %s',
		'Removed from the active pool: %s': 'Убран из активного пула: %s',
		'Traffic': 'Трафик', 'connections': 'соединений', 'total': 'всего',
		'VPN Pool — Sources': 'VPN Pool — Источники', 'Main subscription': 'Основная подписка',
		'Save URL': 'Сохранить URL', 'Delete subscription': 'Удалить подписку',
		'Subscription URL saved.': 'URL подписки сохранён.', 'Delete the subscription URL?': 'Удалить URL подписки?',
		'Subscription deleted.': 'Подписка удалена.', 'Source added.': 'Источник добавлен.',
		'Node added.': 'Узел добавлен.', 'Update interval saved.': 'Интервал обновления сохранён.',
		'Updating from all sources…': 'Обновляю из всех источников…',
		'(no extra sources)': '(нет доп. источников)', '(no manual nodes)': '(нет ручных узлов)',
		'Auto-update interval': 'Интервал автообновления', 'e.g. 6h, 30m, 12h': 'напр. 6h, 30m, 12h',
		'Extra sources (auto-updating raw files)': 'Доп. источники (автообновляемые raw-файлы)',
		'Add raw URLs that contain vless:// lists or base64 subscriptions (e.g. auto-updating repo files).':
			'Добавьте raw-URL со списком vless:// или base64-подпиской (напр. автообновляемые файлы репозитория).',
		'Manual VLESS nodes': 'Ручные VLESS-узлы',
		'VPN Pool — Routing': 'VPN Pool — Маршрутизация', 'Routing mode': 'Режим маршрутизации',
		'Save mode': 'Сохранить режим',
		'Proxy only the selected lists/domains (rest direct)': 'Проксировать только выбранные списки/домены (остальное напрямую)',
		'Proxy everything EXCEPT the selected lists/domains': 'Проксировать всё, КРОМЕ выбранных списков/доменов',
		'Routing mode saved and applied.': 'Режим сохранён и применён.',
		'Community lists saved and applied.': 'Списки сообществ сохранены и применены.',
		'Domains saved and applied.': 'Домены сохранены и применены.',
		'Community lists (itdoginfo/allow-domains, auto-updated SRS)': 'Списки сообществ (itdoginfo/allow-domains, авто-SRS)',
		'Save lists': 'Сохранить списки', 'Custom domains (one per line)': 'Свои домены (по одному в строке)',
		'Save domains': 'Сохранить домены',
		'Per-client routing': 'Маршрутизация по устройствам', 'All LAN clients': 'Все клиенты сети',
		'All except the listed clients (listed bypass VPN)': 'Все, кроме перечисленных (перечисленные мимо VPN)',
		'Only the listed clients use the VPN': 'Только перечисленные клиенты через VPN',
		'Client IPv4 addresses, one per line:': 'IPv4-адреса клиентов, по одному в строке:',
		'Save per-client': 'Сохранить', 'Per-client routing saved and applied.': 'Маршрутизация по устройствам сохранена и применена.',
		'Devices on the network (matched by MAC — survives IP changes):': 'Устройства в сети (сопоставление по MAC — переживает смену IP):',
		'Extra IPv4 addresses, one per line (for static / unknown hosts):': 'Дополнительные IPv4-адреса, по одному в строке (для статических / неизвестных хостов):',
		'No devices seen yet (DHCP leases are empty).': 'Устройства пока не обнаружены (список DHCP пуст).',
		'offline': 'офлайн',
		'VPN Pool — Settings': 'VPN Pool — Настройки', 'Saved: %s': 'Сохранено: %s',
		'Auto-ping & failover': 'Автопинг и переключение', 'Auto-ping interval (sec)': 'Интервал автопинга (сек)',
		'Switch tolerance (ms)': 'Допуск переключения (мс)',
		'Auto-switch to a working node (urltest)': 'Авто-переключение на рабочий узел (urltest)',
		'Preferred node': 'Предпочитаемый узел', '— auto (urltest) —': '— авто (urltest) —',
		'Preferred node: stick to it while it is reachable, hand over to auto if it dies, switch back when it recovers.':
			'Предпочитаемый узел: держимся за него, пока он доступен; при падении передаём управление авто-режиму, а после восстановления возвращаемся обратно.',
		'Preferred node is now set right on the Dashboard — click 📌 on any node to pin it (used while reachable, auto-failover if it dies, switch back on recovery).':
			'Предпочитаемый узел теперь задаётся прямо на Дашборде — нажмите 📌 у любого узла (используется пока доступен, авто-переключение при падении, возврат при восстановлении).',
		'Preferred node (soft pin with switch-back)': 'Предпочитаемый узел (мягкий пин с возвратом)',
		'Make preferred (soft pin: used while reachable, auto-failover if it dies, switch back on recovery)':
			'Сделать предпочитаемым (мягкий пин: используется пока доступен, авто-переключение при падении, возврат при восстановлении)',
		'Preferred node — click to unpin (back to auto)': 'Предпочитаемый узел — нажмите, чтобы снять (обратно в авто)',
		'Preferred node: %s': 'Предпочитаемый узел: %s', 'Preferred node cleared (auto)': 'Предпочитаемый узел снят (авто)',
		'Security / leak protection': 'Безопасность / защита от утечек',
		'Kill-switch (block all traffic if VPN is down)': 'Kill-switch (блокировать весь трафик, если VPN недоступен)',
		'DNS-leak protection (route LAN DNS through the tunnel)': 'Защита от DNS-утечек (DNS из LAN через туннель)',
		'Kill-switch fails closed in full-tunnel (exclude) mode. DNS protection sends LAN DNS queries through the VPN so they can’t leak to your ISP.':
			'Kill-switch работает в режиме полного туннеля (исключения): при падении VPN трафик не уходит напрямую. Защита DNS отправляет DNS-запросы LAN через VPN, чтобы они не утекали провайдеру.',
		'Data quota': 'Объём трафика', '%s left': 'осталось %s',
		'Telegram alerts': 'Уведомления в Telegram', 'Enable Telegram notifications': 'Включить уведомления в Telegram',
		'Bot token': 'Токен бота', 'Chat ID': 'Chat ID', 'Send test': 'Тест', 'Telegram settings saved.': 'Настройки Telegram сохранены.',
		'Sending test message…': 'Отправляю тестовое сообщение…', 'Test sent — check Telegram.': 'Отправлено — проверьте Telegram.',
		'Telegram send failed (HTTP %s) — check token/chat id.': 'Не удалось отправить (HTTP %s) — проверьте токен/chat id.',
		'Create a bot via @BotFather, get your chat id (e.g. @userinfobot). Alerts: failover, subscription expiry, start/stop.':
			'Создайте бота через @BotFather, узнайте chat id (напр. @userinfobot). Алерты: переключение узла, истечение подписки, старт/стоп.',
		'Telegram alerts & control': 'Telegram: уведомления и управление',
		'Two-way control bot (/status, /nodes, /switch, /on, /off, /refresh)': 'Двусторонний бот управления (/status, /nodes, /switch, /on, /off, /refresh)',
		'Reach Telegram through the tunnel (needed where Telegram is blocked)': 'Доступ к Telegram через туннель (нужно там, где Telegram заблокирован)',
		'Test what this node unblocks': 'Проверить, что разблокирует узел',
		'Testing what %s unblocks… (router traffic briefly uses this node)': 'Проверка разблокировки %s… (трафик роутера ненадолго пойдёт через этот узел)',
		'Unlock test done for %s.': 'Проверка разблокировки выполнена для %s.',
		'Unlock test failed for %s.': 'Проверка разблокировки не удалась для %s.',
		'Anti-DPI & adaptive routing': 'Анти-DPI и адаптивная маршрутизация',
		'Anti-DPI: fragment the TLS handshake (defeats SNI blocking)': 'Анти-DPI: фрагментировать TLS-хендшейк (обход SNI-блокировок)',
		'Needs sing-box ≥ 1.12. If your build does not support it, the service keeps the previous config (no effect).':
			'Требуется sing-box ≥ 1.12. Если ваша сборка не поддерживает — сервис сохранит прежний конфиг (без эффекта).',
		'Adaptive routing: auto-route sites that are blocked for a direct connection': 'Адаптивная маршрутизация: авто-направлять в VPN сайты, заблокированные напрямую',
		'Scan now': 'Сканировать сейчас', 'Site is blocked?': 'Сайт заблокирован?', 'Route via VPN': 'Направить в VPN',
		'Auto-routed domains': 'Авто-маршрутизированные домены',
		'(none yet — detected blocked sites will appear here)': '(пока пусто — найденные заблокированные сайты появятся здесь)',
		'Enter a domain first.': 'Сначала введите домен.', 'Domain added to VPN route.': 'Домен добавлен в VPN-маршрут.',
		'Adaptive scan started…': 'Адаптивное сканирование запущено…',
		'Smart bypass (direct DPI defeat via zapret)': 'Умный обход (прямой обход DPI через zapret)',
		'Self-learn DPI-blocked sites and defeat them DIRECTLY (no proxy, survives throttling)': 'Самообучение на заблокированных DPI сайтах и их обход НАПРЯМУЮ (без прокси, переживает троттлинг)',
		'Install zapret': 'Установить zapret',
		'zapret is not installed. vpnpool only orchestrates it (never bundles nfqws).': 'zapret не установлен. vpnpool только управляет им (не встраивает nfqws).',
		'downloads the upstream package for your router and installs it': 'скачает официальный пакет под ваш роутер и установит его',
		'Installing zapret (downloading + opkg)… this can take a minute.': 'Устанавливаю zapret (загрузка + opkg)… это может занять минуту.',
		'zapret is already installed.': 'zapret уже установлен.',
		'zapret installed (%s). Reloading…': 'zapret установлен (%s). Перезагрузка…',
		'zapret install failed at "%s": %s': 'Установка zapret не удалась на шаге «%s»: %s',
		'zapret detected (mode: %s). Self-learned domains so far: %s. Needs a separate zapret install; vpnpool only switches it to self-learning mode.': 'zapret обнаружен (режим: %s). Самообученных доменов: %s. Нужна отдельная установка zapret; vpnpool лишь переключает его в режим самообучения.',
		'zapret is not installed. Install the zapret package to enable smart bypass; vpnpool only orchestrates it (never bundles nfqws).': 'zapret не установлен. Поставьте пакет zapret, чтобы включить умный обход; vpnpool только управляет им (не встраивает nfqws).',
		'Auto-save working nodes': 'Авто-сохранение рабочих узлов',
		'Periodically snapshot reachable nodes to the saved store': 'Периодически сохранять доступные узлы в постоянную память',
		'Keep at most (nodes)': 'Хранить не более (узлов)',
		'Builds a fallback set that survives subscription expiry. Manual ⭐ saves are never evicted.':
			'Формирует резервный набор, который остаётся после окончания подписки. Ручные ⭐ никогда не вытесняются.',
		'Auto-snapshot settings saved.': 'Настройки авто-снимка сохранены.',
		'Schedule': 'Расписание', 'Schedule saved.': 'Расписание сохранено.', 'Enable schedule': 'Включить расписание',
		'Turn ON at (HH:MM)': 'Включать в (ЧЧ:ММ)', 'Turn OFF at (HH:MM)': 'Выключать в (ЧЧ:ММ)',
		'Refresh subscription at (HH:MM)': 'Обновлять подписку в (ЧЧ:ММ)',
		'Router local time. Leave a field empty to skip that action. Uses cron.':
			'Локальное время роутера. Пустое поле — действие пропускается. Использует cron.',
		'Speed': 'Скорость', 'Actions': 'Действия', 'Mbit/s': 'Мбит/с',
		'Search node / server…': 'Поиск узла / сервера…',
		'Sort: ping': 'Сортировка: пинг', 'Sort: name': 'Сортировка: имя', 'Sort: traffic': 'Сортировка: трафик',
		'reachable only': 'только доступные', 'No nodes match the filter.': 'Нет узлов по фильтру.',
		'Saved': 'Сохранён', 'Remove from saved': 'Убрать из сохранённых',
		'Save node (keep after subscription expires)': 'Сохранить узел (останется после окончания подписки)',
		'Real speed test': 'Тест реальной скорости',
		'Node saved: %s': 'Узел сохранён: %s', 'Node removed from saved: %s': 'Узел убран из сохранённых: %s',
		'Speed-testing %s… (router traffic briefly uses this node)': 'Тест скорости %s… (трафик роутера ненадолго пойдёт через этот узел)',
		'%s: %s Mbit/s': '%s: %s Мбит/с', 'Speed test failed for %s.': 'Тест скорости не удался для %s.',
		'%s Mbit/s': '%s Мбит/с',
		'Not enough free memory for a speed test: %s MB free, need ≥ %s MB. Skipped to keep the VPN stable.':
			'Недостаточно свободной памяти для теста скорости: свободно %s МБ, нужно ≥ %s МБ. Пропущено ради стабильности VPN.',
		'Per-client traffic': 'Трафик по устройствам', 'No active client connections.': 'Нет активных подключений устройств.',
		'Device': 'Устройство', 'IP': 'IP',
		'Share link / QR': 'Ссылка / QR', 'Share node': 'Поделиться узлом',
		'QR library unavailable.': 'QR-библиотека недоступна.',
		'No shareable link for this node.': 'Для этого узла нет ссылки для шеринга.',
		'Scan the QR with your phone VPN app, or copy the link.': 'Отсканируйте QR в VPN-приложении на телефоне или скопируйте ссылку.',
		'Copy link': 'Копировать ссылку', 'Close': 'Закрыть',
		'Export': 'Экспорт', 'Export nodes as subscription': 'Экспорт узлов как подписки',
		'Pick which nodes to export. You get the raw vless:// links and a base64 subscription you can import elsewhere.':
			'Выберите узлы для экспорта. Получите готовые vless://-ссылки и base64-подписку для импорта в другом месте.',
		'All nodes': 'Все узлы', 'Nothing to export in this set.': 'В этом наборе нечего экспортировать.',
		'%d nodes': 'узлов: %d', 'Copy base64': 'Копировать base64', 'Download': 'Скачать',
		'Copy': 'Копировать', 'vless:// links': 'vless://-ссылки', 'base64 subscription': 'base64-подписка',
		'Extra subscriptions': 'Дополнительные подписки',
		'Additional full subscriptions are bulk-merged into the pool alongside the main one (quota/expiry come only from the main subscription).':
			'Дополнительные полные подписки целиком подмешиваются в пул вместе с основной (квота/срок берутся только из основной подписки).',
		'Add subscription': 'Добавить подписку', '(no extra subscriptions)': '(нет дополнительных подписок)',
		'Enter a subscription URL first.': 'Сначала введите URL подписки.',
		'Extra subscription added — fetching…': 'Доп. подписка добавлена — загружаю…',
		'Extra subscription removed.': 'Доп. подписка удалена.',
		'Create a bot via @BotFather, get your chat id (e.g. @userinfobot). Alerts: failover, subscription expiry, start/stop. The control bot only obeys your chat id.':
			'Создайте бота через @BotFather, узнайте chat id (напр. @userinfobot). Алерты: переключение узла, истечение подписки, старт/стоп. Бот управления слушает только ваш chat id.',
		'Backup / Restore': 'Бэкап / Восстановление', 'Export': 'Экспорт', 'Import': 'Импорт',
		'Configuration imported. Reloading…': 'Конфигурация импортирована. Перезагрузка…',
		'Replace the current vpnpool configuration with the pasted backup?': 'Заменить текущую конфигурацию vpnpool вставленным бэкапом?',
		'Export fills the box with your config — copy it somewhere safe. Paste a backup and Import to restore.':
			'Экспорт заполнит поле вашей конфигурацией — сохраните её. Вставьте бэкап и нажмите Импорт для восстановления.',
		'Technical (read-only)': 'Технические (только чтение)', 'sing-box version': 'версия sing-box',
		'tproxy port': 'порт tproxy', 'fwmark': 'fwmark', 'route table': 'таблица маршрутов',
		'Clash API': 'Clash API',
		'These coexist with podkop (mark 0x100000, table podkop, :1602) and must not collide.':
			'Сосуществуют с podkop (mark 0x100000, table podkop, :1602) и не должны пересекаться.',
		'VPN Pool — Diagnostics': 'VPN Pool — Диагностика', 'Service': 'Служба',
		'Enabled': 'Включена', 'Daemon running': 'Демон работает', 'Routing active': 'Маршрутизация активна',
		'Autostart on boot': 'Автозапуск при загрузке', 'sing-box PID': 'PID sing-box',
		'Clash API reachable': 'Clash API доступен', 'Coexistence': 'Сосуществование',
		'podkop running': 'podkop работает', 'podkop nft table': 'nft-таблица podkop',
		'zapret nft table': 'nft-таблица zapret', 'Network (direct / ISP path)': 'Сеть (прямой / ISP-путь)',
		'Internet (direct)': 'Интернет (напрямую)', 'WAN interface': 'WAN-интерфейс', 'Gateway': 'Шлюз',
		'Direct egress IP': 'Выходной IP (прямой)', 'Direct egress country': 'Страна выхода (прямой)',
		'This is your ISP exit (traffic NOT via VPN). Proxied nodes exit elsewhere — see Dashboard pings.':
			'Это выход через провайдера (НЕ через VPN). Проксированные узлы выходят иначе — см. пинги на Дашборде.',
		'Resources': 'Ресурсы', 'fwmark / table': 'fwmark / таблица', 'Recent logs': 'Последние логи',
		'(no logs)': '(логов нет)',
		'Community rule-sets': 'Списки сообществ (rule-set)', 'Lists configured': 'Списков настроено',
		'SRS cache present': 'SRS-кэш есть', 'SRS cache size (KB)': 'Размер SRS-кэша (КБ)',
		'Test exit via VPN': 'Проверить выход через VPN', 'Testing exit via VPN…': 'Проверяю выход через VPN…',
		'VPN exit: %s  (IP %s)': 'Выход через VPN: %s  (IP %s)',
		'VPN exit test failed — is the service running?': 'Тест выхода не удался — служба запущена?',
		'Imported': 'Импортированные', 'Manual': 'Ручные',
		'Import from a source list': 'Импорт из списка-источника',
		'Paste a URL with a vless:// list or base64 subscription, fetch it, then pick the nodes you want. Picked nodes join the pool and show under their own group in the dashboard.': 'Вставьте URL со списком vless:// или base64-подпиской, загрузите и выберите нужные узлы. Выбранные войдут в пул и появятся в дашборде отдельной группой.',
		'Fetch & pick': 'Загрузить и выбрать', 'Saved sources': 'Сохранённые источники',
		'(no saved sources yet)': '(пока нет сохранённых источников)',
		'Update': 'Обновить', 'Re-fetch this source and pick nodes': 'Перезагрузить источник и выбрать узлы',
		'Enter a source URL first.': 'Сначала введите URL источника.',
		'Fetching source…': 'Загрузка источника…',
		'Fetching and pinging nodes — this can take up to ~30 seconds.': 'Загрузка и пинг узлов — до ~30 секунд.',
		'Fetching and pinging nodes — this can take up to a minute on slow routers.': 'Загрузка и пинг узлов — до минуты на медленных роутерах.',
		'Probe timed out.': 'Проба не уложилась во время.',
		'No usable nodes from this source': 'Из этого источника нет пригодных узлов',
		'Probe failed': 'Ошибка загрузки', 'Pick nodes to import': 'Выберите узлы для импорта',
		'Selected nodes join the auto-switch pool and appear in the dashboard under this source.': 'Выбранные узлы войдут в авто-пул и появятся в дашборде отдельным разделом.',
		'Ping is ICMP (a server may block it — you can still pick it; the real latency shows in the dashboard).': 'Пинг — ICMP (сервер может его блокировать; узел всё равно можно выбрать — реальная задержка появится в дашборде).',
		'%d nodes': '%d узлов',
		'(showing first %d of %d — narrow the source if you need more)': '(показаны первые %d из %d — сузьте источник, если нужно больше)',
		'All reachable': 'Все доступные', 'All': 'Все', 'None': 'Никакие',
		'Save selection': 'Сохранить выбор', 'Importing %d nodes…': 'Импортирую %d узлов…',
		'Imported %d nodes from this source.': 'Импортировано %d узлов из источника.'
	}
};

var LANG = (function () {
	var b = (navigator.language || navigator.userLanguage || 'en').toLowerCase();
	return (b.indexOf('ru') === 0) ? 'ru' : 'en';
})();

// Inject the responsive stylesheet ONCE (this module is required by every vpnpool
// view). On phones (<=600px) the dense tables reflow into wrapping cards and fixed
// inline labels stack above full-width inputs, so nothing is clipped or scrolls sideways.
(function injectResponsiveCss() {
	if (typeof document === 'undefined' || document.getElementById('vpnpool-responsive')) return;
	var css = [
		'@media (max-width:600px){',
		'.vpnpool-view .table{display:block;min-width:0 !important;width:100%}',
		'.vpnpool-view .table .tr.table-titles{display:none}',
		'.vpnpool-view .table .tr{display:flex;flex-wrap:wrap;align-items:baseline;gap:2px 10px;border:1px solid #e6e6e6;border-radius:8px;margin:0 0 8px;padding:6px 8px}',
		'.vpnpool-view .table .td{border:0 !important;padding:1px 0 !important;white-space:normal !important;max-width:100%}',
		'.vpnpool-view b[style*="inline-block"],.vpnpool-view label[style*="inline-block"]{display:block !important;width:auto !important;margin-bottom:2px}',
		'.vpnpool-view input,.vpnpool-view select,.vpnpool-view textarea{max-width:100% !important;box-sizing:border-box}',
		'.vpnpool-view input.cbi-input-text[style*="width"]{width:100% !important}',
		'.vpnpool-view div[style*="width:280px"]{width:100% !important;max-width:280px}',
		'}'
	].join('\n');
	var st = document.createElement('style');
	st.id = 'vpnpool-responsive';
	st.type = 'text/css';
	st.appendChild(document.createTextNode(css));
	(document.head || document.documentElement).appendChild(st);
})();

return baseclass.extend({
	lang: LANG,

	tr: function (s) {
		return (LANG === 'ru' && DICT.ru[s]) ? DICT.ru[s] : s;
	},

	// Page header: just the localized title. Tab labels are set in menu.d (no JS
	// DOM manipulation -> no fight with LuCI's rendering -> no flicker).
	header: function (title) {
		return E('h2', { 'style': 'margin:0 0 10px' }, title);
	}
});

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
		'VPN Pool — Settings': 'VPN Pool — Настройки', 'Saved: %s': 'Сохранено: %s',
		'Auto-ping & failover': 'Автопинг и переключение', 'Auto-ping interval (sec)': 'Интервал автопинга (сек)',
		'Switch tolerance (ms)': 'Допуск переключения (мс)',
		'Auto-switch to a working node (urltest)': 'Авто-переключение на рабочий узел (urltest)',
		'Telegram alerts': 'Уведомления в Telegram', 'Enable Telegram notifications': 'Включить уведомления в Telegram',
		'Bot token': 'Токен бота', 'Chat ID': 'Chat ID', 'Send test': 'Тест', 'Telegram settings saved.': 'Настройки Telegram сохранены.',
		'Sending test message…': 'Отправляю тестовое сообщение…', 'Test sent — check Telegram.': 'Отправлено — проверьте Telegram.',
		'Telegram send failed (HTTP %s) — check token/chat id.': 'Не удалось отправить (HTTP %s) — проверьте токен/chat id.',
		'Create a bot via @BotFather, get your chat id (e.g. @userinfobot). Alerts: failover, subscription expiry, start/stop.':
			'Создайте бота через @BotFather, узнайте chat id (напр. @userinfobot). Алерты: переключение узла, истечение подписки, старт/стоп.',
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

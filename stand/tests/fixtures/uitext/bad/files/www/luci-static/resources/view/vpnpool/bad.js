'use strict';
'require view';
// Positive-control fixture for stand/tests/ui-text-guard.uc: four strings below MUST be
// flagged (urltest, clash, snake_case option name, filesystem path); the rest must not.
return view.extend({
	render: function () {
		return E('div', {}, [
			_('Restart the urltest group'),
			_("Clash API is down"),
			_('Set check_services first'),
			_('Logs are in /tmp/vpnpool'),
			_('A plain, friendly sentence.'),
			_('It\'s fine to say "it\'s" here'),
			foo_('urltest inside a non-gettext call is not UI text')
		]);
	}
});

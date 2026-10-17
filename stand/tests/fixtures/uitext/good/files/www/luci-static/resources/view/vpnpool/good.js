'use strict';
'require view';
// Negative-control fixture for stand/tests/ui-text-guard.uc: nothing here may be flagged.
return view.extend({
	render: function () {
		return E('div', {}, [
			_('Connect'),
			_('Back to automatic choice'),
			_('Subscription expires in %d days'),
			_('Settings saved.')
		]);
	}
});

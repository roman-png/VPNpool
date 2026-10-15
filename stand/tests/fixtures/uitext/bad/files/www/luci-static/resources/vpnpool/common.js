'use strict';
'require baseclass';
// Positive-control fixture: a shared module (not a view) — its _() strings are UI text too.
return baseclass.extend({
	text: function() { return _('The watchdog restarted the tunnel'); }
});

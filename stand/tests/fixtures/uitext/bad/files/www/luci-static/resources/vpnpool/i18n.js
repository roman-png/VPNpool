'use strict';
'require baseclass';

var DICT = {
	ru: {
		// a comment with an apostrophe: don't break the scanner
		'Ping': 'Пинг через rpcd',
		'OK': 'Хорошо'
	}
};

return baseclass.extend({ tr: function (s) { return DICT.ru[s] || s; } });

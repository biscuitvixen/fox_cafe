// Shared Tailwind theme for *.bluefox.cafe pages.
// Sona palette, used as accents on a dark page (not as backgrounds):
//   sides  #302f39  - card surface
//   lining #1e1d28  - page background
//   belly  #497bd6  - primary accent (blue)
//   eyes   #24d962  - secondary accent (green)
window.tailwind = window.tailwind || {};
tailwind.config = {
    theme: {
        extend: {
            colors: {
                sides:  '#302f39',
                lining: '#1e1d28',
                belly:  '#497bd6',
                eyes:   '#24d962',
            },
            boxShadow: {
                float: '0 10px 30px -8px rgba(0,0,0,0.55), 0 2px 6px rgba(0,0,0,0.3)',
                lift:  '0 18px 40px -12px rgba(0,0,0,0.6), 0 4px 10px rgba(73,123,214,0.20)',
            },
            keyframes: {
                'pulse-dot': {
                    '0%, 100%': { opacity: '1',   transform: 'scale(1)'    },
                    '50%':      { opacity: '0.4', transform: 'scale(0.75)' },
                },
            },
            animation: {
                'pulse-dot': 'pulse-dot 2.5s ease-in-out infinite',
            },
        },
    },
};

// Dev URL rewriting - maps production URLs to local dev-server paths.
// Only active when the page is not served from bluefox.cafe.
window.devUrls = {
    _map: {
        'https://dnd.bluefox.cafe':          '/dnd',
        'https://demiplane.bluefox.cafe':    '/preview/demiplane/',
        'https://beastworld.bluefox.cafe':   '/preview/beastworld/',
        'https://files.bluefox.cafe':        '/preview/files/',
    },
    _isDev: window.location.hostname !== 'bluefox.cafe',
    resolve(url) { return this._isDev ? (this._map[url] ?? url) : url; },
};

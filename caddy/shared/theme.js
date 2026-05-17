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
                float: '0 8px 24px -10px rgba(0,0,0,0.55), inset 0 1px 0 rgba(255,255,255,0.04)',
                lift:  '0 20px 44px -14px rgba(0,0,0,0.65), 0 0 0 1px rgba(73,123,214,0.25), inset 0 1px 0 rgba(255,255,255,0.06)',
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

// Theme (dark default / light opt-in).
// The site is authored dark; light is a per-visitor override stored in a
// cookie scoped to .bluefox.cafe so the choice follows the visitor across
// every subdomain (localStorage would not - it is per-origin).
window.bfTheme = {
    COOKIE: 'bf_theme',

    // Shared across *.bluefox.cafe in prod; host-only in local dev.
    _cookieDomain() {
        return location.hostname.endsWith('bluefox.cafe')
            ? '; domain=.bluefox.cafe'
            : '';
    },

    read() {
        const m = document.cookie.match(/(?:^|;\s*)bf_theme=(light|dark)/);
        return m ? m[1] : 'dark';
    },

    write(theme) {
        document.cookie =
            `${this.COOKIE}=${theme}; path=/${this._cookieDomain()}` +
            `; max-age=31536000; SameSite=Lax`;
    },

    // Apply to <html> so CSS can key off it before first paint.
    apply(theme) {
        document.documentElement.setAttribute('data-theme', theme);
    },

    toggle() {
        const next = this.read() === 'light' ? 'dark' : 'light';
        this.write(next);
        this.apply(next);
        this._sync(next);
        return next;
    },

    // Keep the toggle button's icon/label in step with the active theme.
    _sync(theme) {
        const btn = document.getElementById('bf-theme-toggle');
        if (!btn) return;
        const light = theme === 'light';
        btn.setAttribute('aria-pressed', String(light));
        btn.setAttribute(
            'aria-label',
            light ? 'Switch to dark mode' : 'Switch to light mode');
        btn.innerHTML = light
            ? '<i class="fa-solid fa-moon"></i>'
            : '<i class="fa-solid fa-sun"></i>';
    },

    // Build the fixed top-right toggle once the body exists. Injected from
    // JS so individual pages need no markup changes - they already load this.
    _mountToggle() {
        if (document.getElementById('bf-theme-toggle')) return;
        const btn = document.createElement('button');
        btn.id = 'bf-theme-toggle';
        btn.type = 'button';
        btn.addEventListener('click', () => this.toggle());
        document.body.appendChild(btn);
        this._sync(this.read());
    },

    init() {
        // Runs as soon as theme.js is parsed (in <head>, before paint).
        this.apply(this.read());
        if (document.readyState === 'loading') {
            document.addEventListener(
                'DOMContentLoaded', () => this._mountToggle());
        } else {
            this._mountToggle();
        }
    },
};
window.bfTheme.init();

// Dev URL rewriting - maps production URLs to local dev-server paths.
// Only active when the page is not served from bluefox.cafe.
window.devUrls = {
    _map: {
        'https://bluefox.cafe':              '/',
        'https://dnd.bluefox.cafe':          '/dnd',
        'https://demiplane.bluefox.cafe':    '/preview/demiplane/',
        'https://beastworld.bluefox.cafe':   '/preview/beastworld/',
        'https://files.bluefox.cafe':        '/preview/files/',
    },
    _isDev: !window.location.hostname.endsWith('bluefox.cafe'),
    resolve(url) { return this._isDev ? (this._map[url] ?? url) : url; },
};

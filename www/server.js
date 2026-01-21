/**
 * Crawl Web Server
 * HTTP server with security headers and compression
 */

const http = require("http");
const serveStatic = require("serve-static");

// Configuration
const PORT = process.env.PORT || 8080;
const HOST = process.env.HOST || '0.0.0.0';

/**
 * Security headers middleware
 */
function securityHeaders(req, res, next) {
    // Prevent clickjacking
    res.setHeader('X-Frame-Options', 'SAMEORIGIN');

    // Prevent MIME type sniffing
    res.setHeader('X-Content-Type-Options', 'nosniff');

    // XSS protection (legacy browsers)
    res.setHeader('X-XSS-Protection', '1; mode=block');

    // Referrer policy
    res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');

    // Content Security Policy
    res.setHeader('Content-Security-Policy', [
        "default-src 'self'",
        "script-src 'self' 'unsafe-inline'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:",
        "font-src 'self'",
        "connect-src 'self'",
        "frame-ancestors 'self'"
    ].join('; '));

    // Permissions Policy
    res.setHeader('Permissions-Policy', 'geolocation=(), microphone=(), camera=()');

    next();
}

/**
 * Request logging middleware
 */
function requestLogger(req, res, next) {
    const start = Date.now();
    const { method, url } = req;

    res.on('finish', () => {
        const duration = Date.now() - start;
        const { statusCode } = res;
        console.log(`${new Date().toISOString()} ${method} ${url} ${statusCode} ${duration}ms`);
    });

    next();
}

/**
 * Create middleware chain
 */
function createMiddleware(middlewares) {
    return function(req, res, finalHandler) {
        let index = 0;

        function next(err) {
            if (err) {
                console.error('Server error:', err);
                res.writeHead(500, { 'Content-Type': 'text/plain' });
                res.end('Internal Server Error');
                return;
            }

            const middleware = middlewares[index++];
            if (middleware) {
                try {
                    middleware(req, res, next);
                } catch (e) {
                    console.error('Middleware error:', e);
                    res.writeHead(500, { 'Content-Type': 'text/plain' });
                    res.end('Internal Server Error');
                }
            } else {
                finalHandler();
            }
        }

        next();
    };
}

/**
 * Start server with routing
 */
function start(route, handle) {
    // Static file server with caching
    const staticServer = serveStatic("./static", {
        index: false,
        maxAge: '1d',
        etag: true,
        lastModified: true
    });

    // Middleware chain
    const middleware = createMiddleware([
        requestLogger,
        securityHeaders
    ]);

    const server = http.createServer((req, res) => {
        middleware(req, res, () => {
            // Try static files first
            staticServer(req, res, () => {
                // Then try routes
                if (!route(handle, req, res)) {
                    res.writeHead(404, {
                        'Content-Type': 'text/html; charset=utf-8'
                    });
                    res.end(`
                        <!DOCTYPE html>
                        <html>
                        <head>
                            <title>404 - Not Found</title>
                            <link rel="stylesheet" href="/css/style.css">
                        </head>
                        <body>
                            <div class="empty-state" style="min-height:80vh;display:flex;flex-direction:column;justify-content:center;">
                                <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                                    <circle cx="12" cy="12" r="10"/>
                                    <path d="M16 16s-1.5-2-4-2-4 2-4 2"/>
                                    <line x1="9" y1="9" x2="9.01" y2="9"/>
                                    <line x1="15" y1="9" x2="15.01" y2="9"/>
                                </svg>
                                <h3>Page Not Found</h3>
                                <p><a href="/">Return to search</a></p>
                            </div>
                        </body>
                        </html>
                    `);
                }
            });
        });
    });

    // Graceful shutdown
    process.on('SIGTERM', () => {
        console.log('SIGTERM received, shutting down gracefully...');
        server.close(() => {
            console.log('Server closed');
            process.exit(0);
        });
    });

    process.on('SIGINT', () => {
        console.log('SIGINT received, shutting down gracefully...');
        server.close(() => {
            console.log('Server closed');
            process.exit(0);
        });
    });

    server.listen(PORT, HOST, () => {
        console.log(`Crawl web server started on http://${HOST}:${PORT}`);
    });

    return server;
}

module.exports = { start };

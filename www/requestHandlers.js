/**
 * Request handlers for Crawl web UI
 * Provides search, autocomplete, and document cache functionality
 */

const url = require("url");
const querystring = require("querystring");
const { Client } = require('@opensearch-project/opensearch');
const ejs = require("ejs");
const fs = require("fs");
const path = require("path");

// Connection pool - reuse client across requests
let _client = null;

/**
 * Get or create OpenSearch client with connection pooling
 */
function getOpenSearchClient() {
    if (_client) {
        return _client;
    }

    const host = process.env.OPENSEARCH_HOST || 'localhost';
    const port = process.env.OPENSEARCH_PORT || '9200';
    const user = process.env.OPENSEARCH_USER || 'admin';
    const pass = process.env.OPENSEARCH_PASS || 'admin';
    const useSSL = process.env.OPENSEARCH_USE_SSL !== 'false';

    _client = new Client({
        node: `${useSSL ? 'https' : 'http'}://${user}:${pass}@${host}:${port}`,
        ssl: {
            rejectUnauthorized: process.env.OPENSEARCH_VERIFY_CERTS === 'true'
        },
        maxRetries: 3,
        requestTimeout: 30000
    });

    return _client;
}

/**
 * Sanitize user input to prevent injection attacks
 * @param {string} input - Raw user input
 * @param {number} maxLength - Maximum allowed length
 * @returns {string} Sanitized input
 */
function sanitizeInput(input, maxLength = 1000) {
    if (!input || typeof input !== 'string') {
        return '';
    }

    // Trim and limit length
    let sanitized = input.trim().substring(0, maxLength);

    // Remove potentially dangerous characters for OpenSearch query_string
    // Allow most search operators but remove script injection vectors
    sanitized = sanitized
        .replace(/<[^>]*>/g, '')     // Remove HTML tags
        .replace(/javascript:/gi, '') // Remove javascript: protocol
        .replace(/on\w+=/gi, '')      // Remove event handlers
        .replace(/[{}]/g, '')         // Remove braces (prevent script injection)
        .replace(/\\/g, '\\\\');      // Escape backslashes

    return sanitized;
}

/**
 * Validate index name to prevent unauthorized access
 * @param {string} indexName - Index name from URL
 * @returns {string|null} Validated index name or null
 */
function validateIndexName(indexName) {
    if (!indexName || typeof indexName !== 'string') {
        return null;
    }

    // Only allow alphanumeric, dash, underscore
    if (!/^[a-zA-Z0-9_-]+$/.test(indexName)) {
        return null;
    }

    // Prevent access to system indexes
    if (indexName.startsWith('.') || indexName.startsWith('_')) {
        return null;
    }

    return indexName;
}

/**
 * Escape HTML entities to prevent XSS
 * @param {string} str - Input string
 * @returns {string} HTML-escaped string
 */
function escapeHtml(str) {
    if (!str) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

/**
 * Send error response
 */
function sendError(response, statusCode, message) {
    response.writeHead(statusCode, { "Content-Type": "text/html; charset=utf-8" });
    response.end(`<html><body><h1>Error ${statusCode}</h1><p>${escapeHtml(message)}</p></body></html>`);
}

/**
 * Home page handler
 */
function start(response) {
    const templatePath = path.join(__dirname, "templates/index.html");

    fs.readFile(templatePath, "utf8", function(err, data) {
        if (err) {
            console.error("Error loading template:", err);
            sendError(response, 500, "Internal server error");
            return;
        }

        response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        response.write(data);
        response.end();
    });
}

/**
 * Autocomplete handler - provides search suggestions
 */
function autocomplete(response, request) {
    const parsedUrl = url.parse(request.url);
    const params = querystring.parse(parsedUrl.query);

    const query = sanitizeInput(params.q, 200);
    const index = validateIndexName(parsedUrl.pathname.split('/').slice(-2, -1)[0]);

    if (!query) {
        response.writeHead(200, { "Content-Type": "application/json" });
        response.end("[]");
        return;
    }

    if (!index) {
        response.writeHead(400, { "Content-Type": "application/json" });
        response.end(JSON.stringify({ error: "Invalid index name" }));
        return;
    }

    const client = getOpenSearchClient();

    client.search({
        index: index,
        body: {
            from: 0,
            size: 10,
            query: {
                query_string: {
                    query: query,
                    fields: ["inurl^100", "intitle^50", "intext^5"],
                    default_operator: "AND",
                    fuzziness: "AUTO",
                    analyzer: "autocomplete"
                }
            },
            highlight: {
                order: "score",
                fields: {
                    "*": {
                        pre_tags: [""],
                        post_tags: [""],
                        fragment_size: 25,
                        number_of_fragments: 1
                    }
                }
            }
        }
    })
    .then(function(res) {
        const matches = [];
        const hits = res.body.hits.hits;

        for (let i = 0; i < hits.length; i++) {
            const highlight = hits[i].highlight || {};
            for (const field in highlight) {
                if (highlight[field] && highlight[field][0]) {
                    matches.push(highlight[field][0]);
                }
            }
        }

        response.writeHead(200, { "Content-Type": "application/json" });
        response.end(JSON.stringify(matches));
    })
    .catch(function(err) {
        console.error("Autocomplete error:", err.message);
        response.writeHead(500, { "Content-Type": "application/json" });
        response.end(JSON.stringify({ error: "Search failed" }));
    });
}

/**
 * Document cache handler - retrieve full document content
 */
function cache(response, request) {
    const parsedUrl = url.parse(request.url);
    const params = querystring.parse(parsedUrl.query);

    const docId = sanitizeInput(params.id, 64);
    const index = validateIndexName(parsedUrl.pathname.split('/').slice(-2, -1)[0]);

    if (!docId) {
        sendError(response, 400, "Document ID required");
        return;
    }

    if (!index) {
        sendError(response, 400, "Invalid index name");
        return;
    }

    const client = getOpenSearchClient();

    client.get({
        index: index,
        id: docId
    })
    .then(function(res) {
        response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        // Content is stored as plain text, escape for display
        const content = res.body._source.intext || '';
        response.end(`<pre>${escapeHtml(content)}</pre>`);
    })
    .catch(function(err) {
        console.error("Cache error:", err.message);
        if (err.meta && err.meta.statusCode === 404) {
            sendError(response, 404, "Document not found");
        } else {
            sendError(response, 500, "Failed to retrieve document");
        }
    });
}

/**
 * Main search handler
 */
function search(response, request) {
    const parsedUrl = url.parse(request.url);
    const params = querystring.parse(parsedUrl.query);

    const query = sanitizeInput(params.q, 1000);
    const offset = Math.max(1, parseInt(params.o) || 1);
    const index = validateIndexName(parsedUrl.pathname.split('/').slice(-2, -1)[0]);
    const isJson = params.json !== undefined;
    const isImages = params.images === '1';
    const count = isImages ? 40 : 10;

    if (!query) {
        sendError(response, 400, "Search query required");
        return;
    }

    if (!index) {
        sendError(response, 400, "Invalid index name");
        return;
    }

    const client = getOpenSearchClient();

    client.search({
        index: index,
        body: {
            from: offset * count - count,
            size: count,
            query: {
                query_string: {
                    query: query,
                    fields: ["inurl^100", "intitle^50", "intext^5"],
                    default_operator: "AND",
                    fuzziness: "AUTO",
                    analyzer: "default"
                }
            },
            highlight: {
                order: "score",
                fields: {
                    "*": {
                        pre_tags: ["_b_"],
                        post_tags: ["_/b_"],
                        fragment_size: 250,
                        number_of_fragments: 3
                    }
                }
            }
        }
    })
    .then(function(res) {
        const found = res.body.hits.total.value;
        const pages = [];

        for (let i = 0; i < res.body.hits.hits.length; i++) {
            const hit = res.body.hits.hits[i];
            const source = hit._source;
            const highlight = hit.highlight || {};

            const id = hit._id;
            const relevant = hit._score;
            const timestamp = source.timestamp;
            let title = source.inurl.split('/').slice(-1)[0];
            let urlValue = source.inurl;
            const filetype = source.filetype;
            const server = source.server || '';
            const share = source.share || '';

            // Generate clickable href
            let href;
            if (urlValue.startsWith('file://') ||
                urlValue.startsWith('http://') ||
                urlValue.startsWith('https://') ||
                urlValue.startsWith('ftp://')) {
                href = urlValue;
            } else {
                href = urlValue.split('/')[0] + '://' + urlValue.split('/').slice(1).join('/');
            }

            // Apply highlights
            const matches = [];
            for (const field in highlight) {
                if (field === 'inurl') {
                    urlValue = highlight[field][0];
                } else if (field === 'intitle') {
                    title = highlight[field][0];
                } else if (field === 'intext') {
                    matches.push(highlight[field].join(' ... '));
                }
            }

            pages.push({
                cache: "/" + index + "/cache?id=" + encodeURIComponent(id),
                title: title.replace(/_b_/g, '<b>').replace(/_\/b_/g, '</b>'),
                href: escapeHtml(href),
                url: urlValue.replace(/_b_/g, '<b>').replace(/_\/b_/g, '</b>'),
                filetype: escapeHtml(filetype),
                relevant: relevant,
                timestamp: escapeHtml(timestamp),
                server: escapeHtml(server),
                share: escapeHtml(share),
                matches: escapeHtml(matches.join(' ... '))
                    .replace(/_b_/g, '<b>')
                    .replace(/_\/b_/g, '</b>')
            });
        }

        // JSON response
        if (isJson) {
            response.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
            response.end(JSON.stringify(pages));
            return;
        }

        // HTML response
        const templateFile = isImages ? "templates/images.html" : "templates/search.html";
        const templatePath = path.join(__dirname, templateFile);

        fs.readFile(templatePath, "utf8", function(err, data) {
            if (err) {
                console.error("Template error:", err);
                sendError(response, 500, "Internal server error");
                return;
            }

            const searchQuery = isImages && !query.includes("filetype:image")
                ? query + " filetype:image"
                : query;

            const html = ejs.render(data, {
                found: found,
                query: escapeHtml(searchQuery),
                pages: pages,
                offset: offset
            });

            response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
            response.end(html);
        });
    })
    .catch(function(err) {
        console.error("Search error:", err.message);
        sendError(response, 500, "Search failed");
    });
}

/**
 * Statistics API handler - returns index statistics as JSON
 */
function apiStats(response, request) {
    const parsedUrl = url.parse(request.url);
    const index = validateIndexName(parsedUrl.pathname.split('/').slice(-3, -2)[0]);

    const client = getOpenSearchClient();

    // Get cluster stats
    Promise.all([
        client.cat.indices({ format: 'json' }),
        client.cluster.health()
    ])
    .then(function([indicesRes, healthRes]) {
        const indices = indicesRes.body || [];
        const health = healthRes.body || {};

        // Filter and format index stats
        const indexStats = indices
            .filter(idx => !idx.index.startsWith('.'))
            .map(idx => ({
                name: idx.index,
                docs: parseInt(idx['docs.count']) || 0,
                size: idx['store.size'] || '0b',
                health: idx.health
            }));

        // Calculate totals
        const totalDocs = indexStats.reduce((sum, idx) => sum + idx.docs, 0);
        const totalIndices = indexStats.length;

        const stats = {
            cluster: {
                status: health.status,
                nodes: health.number_of_nodes,
                shards: health.active_shards
            },
            totals: {
                documents: totalDocs,
                indices: totalIndices
            },
            indices: indexStats,
            timestamp: new Date().toISOString()
        };

        response.writeHead(200, {
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "max-age=30"
        });
        response.end(JSON.stringify(stats));
    })
    .catch(function(err) {
        console.error("Stats API error:", err.message);
        response.writeHead(500, { "Content-Type": "application/json" });
        response.end(JSON.stringify({ error: "Failed to fetch statistics" }));
    });
}

/**
 * Statistics dashboard page
 */
function stats(response, request) {
    const templatePath = path.join(__dirname, "templates/stats.html");

    fs.readFile(templatePath, "utf8", function(err, data) {
        if (err) {
            console.error("Error loading stats template:", err);
            sendError(response, 500, "Internal server error");
            return;
        }

        response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        response.write(data);
        response.end();
    });
}

// Export handlers
exports.start = start;
exports.search = search;
exports.autocomplete = autocomplete;
exports.cache = cache;
exports.stats = stats;
exports.apiStats = apiStats;

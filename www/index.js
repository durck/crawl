/**
 * Crawl Web Application Entry Point
 */

const server = require("./server");
const router = require("./router");
const requestHandlers = require("./requestHandlers");

// Route handlers
const handle = {
    "": requestHandlers.start,
    "search": requestHandlers.search,
    "auto": requestHandlers.autocomplete,
    "cache": requestHandlers.cache,
    "stats": requestHandlers.stats,
    "api/stats": requestHandlers.apiStats
};

// Start server
server.start(router.route, handle);

console.log("Crawl Web UI initialized");

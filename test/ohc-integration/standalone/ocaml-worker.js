/**
 * OCaml Worker Client
 *
 * A JavaScript client library for communicating with the OCaml toplevel web worker.
 *
 * @example
 * ```javascript
 * import { OcamlWorker } from './ocaml-worker.js';
 *
 * const worker = new OcamlWorker('worker.js');
 *
 * await worker.init({
 *   findlib_requires: [],
 *   findlib_index: 'findlib_index'
 * });
 *
 * const result = await worker.eval('let x = 1 + 2;;');
 * console.log(result.caml_ppf); // "val x : int = 3"
 * ```
 */

/**
 * @typedef {Object} InitConfig
 * @property {string[]} findlib_requires - Findlib packages to require
 * @property {string} [stdlib_dcs] - URL to dynamic CMIs for stdlib
 * @property {string} [findlib_index] - URL to findlib_index file
 */

/**
 * @typedef {Object} Position
 * @property {number} pos_cnum - Character number
 * @property {number} pos_lnum - Line number
 * @property {number} pos_bol - Beginning of line offset
 */

/**
 * @typedef {Object} Location
 * @property {Position} loc_start - Start position
 * @property {Position} loc_end - End position
 */

/**
 * @typedef {Object} MimeVal
 * @property {string} mime_type - MIME type
 * @property {string} data - Data content
 */

/**
 * @typedef {Object} Output
 * @property {number} cell_id - Cell identifier
 * @property {string} stdout - Standard output
 * @property {string} stderr - Standard error
 * @property {string} caml_ppf - OCaml pretty-printed output
 * @property {MimeVal[]} mime_vals - MIME values
 */

/**
 * @typedef {Object} CompletionEntry
 * @property {string} name - Completion name
 * @property {string} kind - Kind (Value, Module, Type, etc.)
 * @property {string} desc - Description
 * @property {string} info - Additional info
 * @property {boolean} deprecated - Whether deprecated
 */

/**
 * @typedef {Object} Completions
 * @property {number} cell_id - Cell identifier
 * @property {Object} completions - Completions data
 * @property {number} completions.from - Start position
 * @property {number} completions.to - End position
 * @property {CompletionEntry[]} completions.entries - Completion entries
 */

/**
 * @typedef {Object} Error
 * @property {string} kind - Error kind
 * @property {Location} loc - Error location
 * @property {string} main - Main error message
 * @property {string[]} sub - Sub-messages
 * @property {string} source - Error source
 */

/**
 * @typedef {Object} TypeInfo
 * @property {Location} loc - Type location
 * @property {string} type_str - Type string
 * @property {string} tail - Tail position info
 */

/**
 * @typedef {Object} OutputAt
 * @property {number} cell_id - Cell identifier
 * @property {number} loc - Character position after phrase (pos_cnum)
 * @property {string} caml_ppf - OCaml pretty-printed output for this phrase
 * @property {MimeVal[]} mime_vals - MIME values for this phrase
 */

export class OcamlWorker {
  /**
   * Create the worker blob URL with proper base URL setup.
   * The worker needs __global_rel_url to find its resources.
   * @private
   */
  static _createWorkerUrl(baseUrl) {
    // Convert relative URL to absolute - importScripts in blob workers needs absolute URLs
    const absoluteBase = new URL(baseUrl, window.location.href).href;
    // Remove the trailing /worker.js to get the base directory
    const baseDir = absoluteBase.replace(/\/worker\.js$/, '');
    const content = `globalThis.__global_rel_url="${baseDir}"\nimportScripts("${absoluteBase}");`;
    return URL.createObjectURL(new Blob([content], { type: "text/javascript" }));
  }

  /**
   * Create a worker from a findlib_index URL.
   * The findlib_index JSON contains compiler info (version, content_hash) and
   * META file paths. This is the single entry point for discovery.
   * @param {string} indexUrl - URL to findlib_index (e.g., '/jtw-output/u/<hash>/findlib_index')
   * @param {string} baseOutputUrl - Base URL of the jtw-output directory (e.g., '/jtw-output')
   * @param {Object} [options] - Options passed to OcamlWorker constructor
   * @returns {Promise<{worker: OcamlWorker, findlib_index: string, stdlib_dcs: string}>}
   */
  static async fromIndex(indexUrl, baseOutputUrl, options = {}) {
    const resp = await fetch(indexUrl);
    if (!resp.ok) throw new Error(`Failed to fetch findlib_index: ${resp.status}`);
    const index = await resp.json();
    const compiler = index.compiler;
    if (!compiler) throw new Error('No compiler info in findlib_index');
    const ver = compiler.version;
    const hash = compiler.content_hash;
    const workerUrl = `${baseOutputUrl}/compiler/${ver}/${hash}/worker.js`;
    const worker = new OcamlWorker(workerUrl, options);
    return { worker, findlib_index: indexUrl, stdlib_dcs: 'lib/ocaml/dynamic_cmis.json' };
  }

  /**
   * Create a new OCaml worker client.
   * @param {string} workerUrl - URL to the worker script (e.g., '_opam/worker.js')
   * @param {Object} [options] - Options
   * @param {number} [options.timeout=30000] - Timeout in milliseconds
   * @param {function(OutputAt): void} [options.onOutputAt] - Callback for incremental output
   */
  constructor(workerUrl, options = {}) {
    const blobUrl = OcamlWorker._createWorkerUrl(workerUrl);
    this.worker = new Worker(blobUrl);
    this.timeout = options.timeout || 30000;
    this.onOutputAt = options.onOutputAt || null;
    this.cellIdCounter = 0;
    this.pendingRequests = new Map();
    this.readyPromise = null;
    this.readyResolve = null;
    this.isReady = false;

    this.worker.onmessage = (event) => this._handleMessage(event.data);
    this.worker.onerror = (error) => this._handleError(error);
  }

  /**
   * Handle incoming messages from the worker.
   * @private
   */
  _handleMessage(data) {
    const msg = typeof data === 'string' ? JSON.parse(data) : data;

    switch (msg.type) {
      case 'ready':
        this.isReady = true;
        if (this.readyResolve) {
          this.readyResolve();
          this.readyResolve = null;
        }
        break;

      case 'init_error':
        if (this.readyResolve) {
          // Convert to rejection
          const reject = this.pendingRequests.get('init')?.reject;
          if (reject) {
            reject(new Error(msg.message));
            this.pendingRequests.delete('init');
          }
        }
        break;

      case 'output_at':
        // Incremental output - accumulate caml_ppf for final output
        if (!this._accumulatedOutput) {
          this._accumulatedOutput = new Map();
        }
        {
          const cellId = msg.cell_id;
          const prev = this._accumulatedOutput.get(cellId) || '';
          this._accumulatedOutput.set(cellId, prev + (msg.caml_ppf || ''));
        }
        if (this.onOutputAt) {
          this.onOutputAt(msg);
        }
        break;

      case 'output':
        // Merge accumulated incremental caml_ppf into the final output
        if (this._accumulatedOutput && this._accumulatedOutput.has(msg.cell_id)) {
          const accumulated = this._accumulatedOutput.get(msg.cell_id);
          if (accumulated && (!msg.caml_ppf || msg.caml_ppf === '')) {
            msg.caml_ppf = accumulated;
          }
          this._accumulatedOutput.delete(msg.cell_id);
        }
        this._resolveRequest(msg.cell_id, msg);
        break;
      case 'completions':
      case 'types':
      case 'errors':
      case 'eval_error':
        this._resolveRequest(msg.cell_id, msg);
        break;

      case 'env_created':
      case 'env_destroyed':
        this._resolveRequest(msg.env_id, msg);
        break;

      default:
        console.warn('Unknown message type:', msg.type);
    }
  }

  /**
   * Handle worker errors.
   * @private
   */
  _handleError(error) {
    console.error('Worker error:', error);
    // Reject all pending requests
    for (const [key, { reject }] of this.pendingRequests) {
      reject(error);
    }
    this.pendingRequests.clear();
  }

  /**
   * Resolve a pending request.
   * @private
   */
  _resolveRequest(id, msg) {
    const pending = this.pendingRequests.get(id);
    if (pending) {
      clearTimeout(pending.timeoutId);
      if (msg.type === 'eval_error') {
        pending.reject(new Error(msg.message));
      } else {
        pending.resolve(msg);
      }
      this.pendingRequests.delete(id);
    }
  }

  /**
   * Send a message to the worker and wait for a response.
   * @private
   */
  _send(msg, id) {
    return new Promise((resolve, reject) => {
      const timeoutId = setTimeout(() => {
        this.pendingRequests.delete(id);
        reject(new Error('Request timeout'));
      }, this.timeout);

      this.pendingRequests.set(id, { resolve, reject, timeoutId });
      this.worker.postMessage(JSON.stringify(msg));
    });
  }

  /**
   * Get the next cell ID.
   * @private
   */
  _nextCellId() {
    return ++this.cellIdCounter;
  }

  /**
   * Initialize the worker.
   * @param {InitConfig} config - Initialization configuration
   * @returns {Promise<void>}
   */
  async init(config) {
    // Set up ready promise
    this.readyPromise = new Promise((resolve, reject) => {
      this.readyResolve = resolve;
      this.pendingRequests.set('init', { resolve, reject, timeoutId: null });
    });

    // Set timeout for init
    const timeoutId = setTimeout(() => {
      this.pendingRequests.delete('init');
      if (this.readyResolve) {
        this.readyResolve = null;
      }
      throw new Error('Init timeout');
    }, this.timeout);

    const pending = this.pendingRequests.get('init');
    if (pending) {
      pending.timeoutId = timeoutId;
    }

    // Send init message
    this.worker.postMessage(JSON.stringify({
      type: 'init',
      findlib_requires: config.findlib_requires || [],
      stdlib_dcs: config.stdlib_dcs || null,
      findlib_index: config.findlib_index || null,
    }));

    // Wait for ready
    await this.readyPromise;
    clearTimeout(timeoutId);
    this.pendingRequests.delete('init');
  }

  /**
   * Wait for the worker to be ready.
   * @returns {Promise<void>}
   */
  async waitReady() {
    if (this.isReady) return;
    if (this.readyPromise) {
      await this.readyPromise;
    }
  }

  /**
   * Evaluate OCaml code.
   * @param {string} code - OCaml code to evaluate
   * @param {string} [envId='default'] - Environment ID
   * @returns {Promise<Output>}
   */
  async eval(code, envId = 'default') {
    await this.waitReady();
    const cellId = this._nextCellId();
    return this._send({
      type: 'eval',
      cell_id: cellId,
      env_id: envId,
      code: code,
    }, cellId);
  }

  /**
   * Get completions at a position.
   * @param {string} source - Source code
   * @param {number} position - Cursor position (character offset)
   * @param {string} [envId='default'] - Environment ID
   * @returns {Promise<Completions>}
   */
  async complete(source, position, envId = 'default') {
    await this.waitReady();
    const cellId = this._nextCellId();
    return this._send({
      type: 'complete',
      cell_id: cellId,
      env_id: envId,
      source: source,
      position: position,
    }, cellId);
  }

  /**
   * Get type information at a position.
   * @param {string} source - Source code
   * @param {number} position - Cursor position (character offset)
   * @param {string} [envId='default'] - Environment ID
   * @returns {Promise<{cell_id: number, types: TypeInfo[]}>}
   */
  async typeAt(source, position, envId = 'default') {
    await this.waitReady();
    const cellId = this._nextCellId();
    return this._send({
      type: 'type_at',
      cell_id: cellId,
      env_id: envId,
      source: source,
      position: position,
    }, cellId);
  }

  /**
   * Get errors for source code.
   * @param {string} source - Source code
   * @param {string} [envId='default'] - Environment ID
   * @returns {Promise<{cell_id: number, errors: Error[]}>}
   */
  async errors(source, envId = 'default') {
    await this.waitReady();
    const cellId = this._nextCellId();
    return this._send({
      type: 'errors',
      cell_id: cellId,
      env_id: envId,
      source: source,
    }, cellId);
  }

  /**
   * Create a new execution environment.
   * @param {string} envId - Environment ID
   * @returns {Promise<{env_id: string}>}
   */
  async createEnv(envId) {
    await this.waitReady();
    return this._send({
      type: 'create_env',
      env_id: envId,
    }, envId);
  }

  /**
   * Destroy an execution environment.
   * @param {string} envId - Environment ID
   * @returns {Promise<{env_id: string}>}
   */
  async destroyEnv(envId) {
    await this.waitReady();
    return this._send({
      type: 'destroy_env',
      env_id: envId,
    }, envId);
  }

  /**
   * Terminate the worker.
   */
  terminate() {
    this.worker.terminate();
    // Reject all pending requests
    for (const [key, { reject, timeoutId }] of this.pendingRequests) {
      clearTimeout(timeoutId);
      reject(new Error('Worker terminated'));
    }
    this.pendingRequests.clear();
  }
}

// Also export as default
export default OcamlWorker;

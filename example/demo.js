/**
 * js_top_worker Feature Demo
 *
 * This JavaScript file demonstrates all features of js_top_worker:
 * - Basic execution
 * - Multiple isolated environments
 * - MIME output (HTML, SVG, images)
 * - Autocomplete
 * - Type information
 * - Error reporting
 * - Directives
 * - Library loading
 */

// ============================================================================
// Worker Communication Setup
// ============================================================================

let worker = null;
let rpcId = 1;
const pendingCalls = new Map();
let currentEnv = "";
let envCount = 0;

function getWorkerURL(baseUrl) {
  // Convert relative URL to absolute - importScripts in blob workers needs absolute URLs
  const absoluteBase = new URL(baseUrl, window.location.href).href;
  const content = `globalThis.__global_rel_url="${absoluteBase}"\nimportScripts("${absoluteBase}/worker.js");`;
  return URL.createObjectURL(new Blob([content], { type: "text/javascript" }));
}

function log(message, type = "info") {
  const entries = document.getElementById("log-entries");
  const entry = document.createElement("div");
  entry.className = `log-entry ${type}`;
  entry.textContent = `[${new Date().toLocaleTimeString()}] ${message}`;
  entries.appendChild(entry);
  entries.parentElement.scrollTop = entries.parentElement.scrollHeight;
  console.log(`[${type}] ${message}`);
}

function setStatus(status, text) {
  const indicator = document.getElementById("status-indicator");
  const statusText = document.getElementById("status-text");
  indicator.className = `status-indicator ${status}`;
  statusText.textContent = text;
}

// RPC call wrapper
function rpc(method, params) {
  return new Promise((resolve, reject) => {
    const id = rpcId++;
    const message = JSON.stringify({ id, method, params });

    pendingCalls.set(id, { resolve, reject });
    worker.postMessage(message);

    log(`RPC: ${method}(${JSON.stringify(params).substring(0, 100)}...)`, "info");
  });
}

// Handle incoming messages from worker
function onWorkerMessage(e) {
  try {
    const response = JSON.parse(e.data);
    if (response.id && pendingCalls.has(response.id)) {
      const { resolve, reject } = pendingCalls.get(response.id);
      pendingCalls.delete(response.id);

      if (response.error) {
        log(`RPC Error: ${JSON.stringify(response.error)}`, "error");
        reject(response.error);
      } else {
        resolve(response.result);
      }
    }
  } catch (err) {
    log(`Parse error: ${err.message}`, "error");
  }
}

// ============================================================================
// Initialization
// ============================================================================

async function initWorker() {
  try {
    setStatus("", "Loading worker...");

    // Create worker from the _opam directory
    const workerUrl = getWorkerURL("_opam");
    worker = new Worker(workerUrl);
    worker.onmessage = onWorkerMessage;
    worker.onerror = (e) => {
      log(`Worker error: ${e.message}`, "error");
      setStatus("error", "Worker error");
    };

    setStatus("", "Initializing toplevel...");

    // Initialize the toplevel - named params are in first element of array
    // Include mime_printer for MIME output support
    await rpc("init", [
      { init_libs: { stdlib_dcs: "lib/ocaml/dynamic_cmis.json", findlib_requires: ["mime_printer"], execute: true } }
    ]);

    log("Toplevel initialized", "success");

    // Setup default environment
    setStatus("", "Setting up default environment...");
    const setupResult = await rpc("setup", [{ env_id: "" }]);
    log("Default environment ready", "success");

    setStatus("ready", "Ready");

    // Show setup blurb
    if (setupResult && setupResult.caml_ppf) {
      log(`OCaml toplevel: ${setupResult.caml_ppf.substring(0, 100)}...`, "info");
    }

  } catch (err) {
    log(`Initialization failed: ${err.message || JSON.stringify(err)}`, "error");
    setStatus("error", "Initialization failed");
  }
}

// ============================================================================
// Output Helpers
// ============================================================================

function formatOutput(result) {
  let html = "";

  if (result.stdout) {
    html += `<div class="output-line stdout"><pre>${escapeHtml(result.stdout)}</pre></div>`;
  }
  if (result.stderr) {
    html += `<div class="output-line stderr"><pre>${escapeHtml(result.stderr)}</pre></div>`;
  }
  if (result.sharp_ppf) {
    html += `<div class="output-line info"><pre>${escapeHtml(result.sharp_ppf)}</pre></div>`;
  }
  if (result.caml_ppf) {
    html += `<div class="output-line result"><pre>${escapeHtml(result.caml_ppf)}</pre></div>`;
  }
  if (result.highlight) {
    const h = result.highlight;
    html += `<div class="output-line info">Highlight: (${h.line1}:${h.col1}) to (${h.line2}:${h.col2})</div>`;
  }

  return html || '<div class="output-line info">No output</div>';
}

function escapeHtml(str) {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function clearOutput(elementId) {
  document.getElementById(elementId).innerHTML = "";
}

// ============================================================================
// Feature: Basic Execution
// ============================================================================

async function runExec() {
  const input = document.getElementById("exec-input").value;
  const output = document.getElementById("exec-output");

  try {
    output.innerHTML = '<div class="output-line info">Executing...</div>';
    const result = await rpc("exec", [{ env_id: "" }, input]);
    output.innerHTML = formatOutput(result);
  } catch (err) {
    output.innerHTML = `<div class="output-line stderr">Error: ${escapeHtml(JSON.stringify(err))}</div>`;
  }
}

// ============================================================================
// Feature: Multiple Environments
// ============================================================================

function updateEnvSelector() {
  const selector = document.getElementById("env-selector");
  const buttons = selector.querySelectorAll(".env-btn");
  buttons.forEach(btn => {
    btn.classList.toggle("active", btn.dataset.env === currentEnv);
  });
}

async function createEnv() {
  const envId = `env${++envCount}`;

  try {
    await rpc("create_env", [{ env_id: envId }]);
    await rpc("setup", [{ env_id: envId }]);

    const selector = document.getElementById("env-selector");
    const btn = document.createElement("button");
    btn.className = "env-btn";
    btn.dataset.env = envId;
    btn.textContent = envId;
    btn.onclick = () => selectEnv(envId);
    selector.appendChild(btn);

    log(`Created environment: ${envId}`, "success");
    selectEnv(envId);
  } catch (err) {
    log(`Failed to create environment: ${err.message || JSON.stringify(err)}`, "error");
  }
}

function selectEnv(envId) {
  currentEnv = envId;
  updateEnvSelector();
  log(`Selected environment: ${envId || "default"}`, "info");
}

async function listEnvs() {
  try {
    const envs = await rpc("list_envs", []);
    const output = document.getElementById("env-output");
    output.innerHTML = `<div class="output-line result">Environments: ${envs.join(", ")}</div>`;
  } catch (err) {
    log(`Failed to list environments: ${err.message || JSON.stringify(err)}`, "error");
  }
}

async function runInEnv() {
  const input = document.getElementById("env-input").value;
  const output = document.getElementById("env-output");

  try {
    output.innerHTML = `<div class="output-line info">Executing in "${currentEnv || "default"}"...</div>`;
    const result = await rpc("exec", [{ env_id: currentEnv }, input]);
    output.innerHTML = formatOutput(result);
  } catch (err) {
    output.innerHTML = `<div class="output-line stderr">Error: ${escapeHtml(JSON.stringify(err))}</div>`;
  }
}

// Make selectEnv available for onclick
document.addEventListener("DOMContentLoaded", () => {
  document.querySelector('.env-btn[data-env=""]').onclick = () => selectEnv("");
});

// ============================================================================
// Feature: MIME Output
// ============================================================================

async function runMime() {
  const input = document.getElementById("mime-input").value;
  const output = document.getElementById("mime-output");
  const rendered = document.getElementById("mime-rendered");

  try {
    output.innerHTML = '<div class="output-line info">Executing...</div>';
    rendered.classList.add("hidden");

    const result = await rpc("exec", [{ env_id: "" }, input]);
    output.innerHTML = formatOutput(result);

    // Render MIME values
    if (result.mime_vals && result.mime_vals.length > 0) {
      rendered.classList.remove("hidden");
      rendered.innerHTML = "";

      for (const mime of result.mime_vals) {
        const div = document.createElement("div");
        div.style.marginBottom = "10px";

        if (mime.mime_type.startsWith("image/svg")) {
          div.innerHTML = mime.data;
        } else if (mime.mime_type.startsWith("image/") && mime.encoding === "Base64") {
          div.innerHTML = `<img src="data:${mime.mime_type};base64,${mime.data}" />`;
        } else if (mime.mime_type === "text/html") {
          div.innerHTML = mime.data;
        } else {
          div.innerHTML = `<pre>${escapeHtml(mime.data)}</pre>`;
        }

        const label = document.createElement("div");
        label.style.fontSize = "0.75rem";
        label.style.color = "#666";
        label.textContent = `MIME: ${mime.mime_type}`;
        div.appendChild(label);

        rendered.appendChild(div);
      }
    }
  } catch (err) {
    output.innerHTML = `<div class="output-line stderr">Error: ${escapeHtml(JSON.stringify(err))}</div>`;
  }
}

function loadMimeExamples() {
  const examples = [
    {
      name: "SVG Circle",
      code: `let svg = {|<svg width="100" height="100">
  <circle cx="50" cy="50" r="40" fill="#89b4fa"/>
  <text x="50" y="55" text-anchor="middle" fill="white">OCaml</text>
</svg>|};;
Mime_printer.push "image/svg" svg;;`
    },
    {
      name: "HTML Table",
      code: `let html = {|<table style="border-collapse: collapse;">
  <tr><th style="border: 1px solid #ccc; padding: 8px;">Name</th><th style="border: 1px solid #ccc; padding: 8px;">Value</th></tr>
  <tr><td style="border: 1px solid #ccc; padding: 8px;">x</td><td style="border: 1px solid #ccc; padding: 8px;">42</td></tr>
  <tr><td style="border: 1px solid #ccc; padding: 8px;">y</td><td style="border: 1px solid #ccc; padding: 8px;">3.14</td></tr>
</table>|};;
Mime_printer.push "text/html" html;;`
    },
    {
      name: "SVG Bar Chart",
      code: `let bars = [20; 45; 30; 60; 35];;
let bar_svg =
  let bar i h =
    Printf.sprintf {|<rect x="%d" y="%d" width="30" height="%d" fill="#89b4fa"/>|} (i * 40 + 10) (100 - h) h
  in
  Printf.sprintf {|<svg width="220" height="110">%s</svg>|}
    (String.concat "" (List.mapi bar bars));;
Mime_printer.push "image/svg" bar_svg;;`
    }
  ];

  const idx = Math.floor(Math.random() * examples.length);
  document.getElementById("mime-input").value = examples[idx].code;
  log(`Loaded example: ${examples[idx].name}`, "info");
}

// ============================================================================
// Feature: Autocomplete
// ============================================================================

async function runComplete() {
  const input = document.getElementById("complete-input").value;
  const output = document.getElementById("complete-output");

  try {
    output.innerHTML = '<div class="completion-item">Loading...</div>';

    // Position at end of input - variants encoded as arrays in rpclib
    const pos = ["Offset", input.length];

    const result = await rpc("complete_prefix", [{ env_id: "", is_toplevel: true }, [], [], input, pos]);

    if (result.entries && result.entries.length > 0) {
      output.innerHTML = result.entries.map(entry => `
        <div class="completion-item">
          <span class="completion-name">${escapeHtml(entry.name)}</span>
          <span class="completion-kind">${escapeHtml(entry.kind)}</span>
        </div>
      `).join("");
    } else {
      output.innerHTML = '<div class="completion-item">No completions found</div>';
    }
  } catch (err) {
    output.innerHTML = `<div class="completion-item">Error: ${escapeHtml(JSON.stringify(err))}</div>`;
  }
}

// ============================================================================
// Feature: Type Information
// ============================================================================

async function runTypeEnclosing() {
  const input = document.getElementById("type-input").value;
  const pos = parseInt(document.getElementById("type-pos").value) || 0;
  const output = document.getElementById("type-output");

  try {
    output.textContent = "Loading...";

    const position = ["Offset", pos];
    const result = await rpc("type_enclosing", [{ env_id: "", is_toplevel: true }, [], [], input, position]);

    if (result && result.length > 0) {
      output.innerHTML = result.map(([loc, typeStr, tailPos]) => {
        const typeText = typeof typeStr === "object" && typeStr.String
          ? typeStr.String
          : (typeof typeStr === "object" && typeStr.Index !== undefined
              ? `(index ${typeStr.Index})`
              : JSON.stringify(typeStr));
        return `<div style="margin-bottom: 5px;">${escapeHtml(typeText)}</div>`;
      }).join("");
    } else {
      output.textContent = "No type information at this position";
    }
  } catch (err) {
    output.textContent = `Error: ${JSON.stringify(err)}`;
  }
}

// ============================================================================
// Feature: Error Reporting
// ============================================================================

async function runQueryErrors() {
  const input = document.getElementById("errors-input").value;
  const output = document.getElementById("errors-output");

  try {
    output.innerHTML = '<div>Analyzing...</div>';

    // Named params: env_id, is_toplevel. Positional: id, dependencies, source
    const result = await rpc("query_errors", [{ env_id: "", is_toplevel: true }, [], [], input]);

    if (result && result.length > 0) {
      output.innerHTML = result.map(err => {
        const isWarning = err.kind && (err.kind.Report_warning || err.kind.Report_alert);
        return `
          <div class="error-item ${isWarning ? 'warning' : ''}">
            <strong>Line ${err.loc.loc_start.pos_lnum}:</strong> ${escapeHtml(err.main)}
            ${err.sub && err.sub.length > 0 ? `<br><small>${err.sub.map(escapeHtml).join("<br>")}</small>` : ""}
          </div>
        `;
      }).join("");
    } else {
      output.innerHTML = '<div style="color: var(--success);">No errors found!</div>';
    }
  } catch (err) {
    output.innerHTML = `<div class="error-item">Analysis error: ${escapeHtml(JSON.stringify(err))}</div>`;
  }
}

// ============================================================================
// Feature: Directives
// ============================================================================

async function runDirective(directive) {
  const input = directive || document.getElementById("directive-input").value;
  const output = document.getElementById("directive-output");

  if (directive) {
    document.getElementById("directive-input").value = directive;
  }

  try {
    output.innerHTML = '<div class="output-line info">Executing...</div>';
    const result = await rpc("exec", [{ env_id: "" }, input]);
    output.innerHTML = formatOutput(result);
  } catch (err) {
    output.innerHTML = `<div class="output-line stderr">Error: ${escapeHtml(JSON.stringify(err))}</div>`;
  }
}

// ============================================================================
// Feature: Custom Printers
// ============================================================================

async function runPrinter() {
  const input = document.getElementById("printer-input").value;
  const output = document.getElementById("printer-output");

  try {
    output.innerHTML = '<div class="output-line info">Executing...</div>';

    // Execute each phrase separately
    const phrases = input.split(";;").filter(p => p.trim()).map(p => p.trim() + ";;");
    let allOutput = "";

    for (const phrase of phrases) {
      const result = await rpc("exec", [{ env_id: "" }, phrase]);
      allOutput += formatOutput(result);
    }

    output.innerHTML = allOutput;
  } catch (err) {
    output.innerHTML = `<div class="output-line stderr">Error: ${escapeHtml(JSON.stringify(err))}</div>`;
  }
}

// ============================================================================
// Feature: Library Loading
// ============================================================================

async function runRequire() {
  const input = document.getElementById("require-input").value;
  const output = document.getElementById("require-output");

  try {
    output.innerHTML = '<div class="output-line info">Executing (loading libraries may take a moment)...</div>';

    // Execute each phrase separately
    const phrases = input.split(";;").filter(p => p.trim()).map(p => p.trim() + ";;");
    let allOutput = "";

    for (const phrase of phrases) {
      const result = await rpc("exec", [{ env_id: "" }, phrase]);
      allOutput += formatOutput(result);
    }

    output.innerHTML = allOutput;
  } catch (err) {
    output.innerHTML = `<div class="output-line stderr">Error: ${escapeHtml(JSON.stringify(err))}</div>`;
  }
}

// ============================================================================
// Feature: Toplevel Script
// ============================================================================

async function runToplevel() {
  const input = document.getElementById("toplevel-input").value;
  const output = document.getElementById("toplevel-output");

  try {
    output.innerHTML = '<div class="output-line info">Executing script...</div>';
    const result = await rpc("exec_toplevel", [{ env_id: "" }, input]);

    if (result.script) {
      output.innerHTML = `<div class="output-line result"><pre>${escapeHtml(result.script)}</pre></div>`;
    } else {
      output.innerHTML = formatOutput(result);
    }

    // Handle MIME output from toplevel
    if (result.mime_vals && result.mime_vals.length > 0) {
      const mimeDiv = document.createElement("div");
      mimeDiv.className = "mime-output";
      mimeDiv.style.marginTop = "10px";

      for (const mime of result.mime_vals) {
        if (mime.mime_type.startsWith("image/svg")) {
          mimeDiv.innerHTML += mime.data;
        } else if (mime.mime_type === "text/html") {
          mimeDiv.innerHTML += mime.data;
        }
      }

      if (mimeDiv.innerHTML) {
        output.appendChild(mimeDiv);
      }
    }
  } catch (err) {
    output.innerHTML = `<div class="output-line stderr">Error: ${escapeHtml(JSON.stringify(err))}</div>`;
  }
}

// ============================================================================
// Initialize on page load
// ============================================================================

document.addEventListener("DOMContentLoaded", initWorker);

/**
 * OCaml Worker Client TypeScript Declarations
 */

export interface InitConfig {
  /** Findlib packages to require */
  findlib_requires: string[];
  /** URL to dynamic CMIs for stdlib */
  stdlib_dcs?: string;
  /** URL to findlib_index file */
  findlib_index?: string;
}

export interface Position {
  /** Character number */
  pos_cnum: number;
  /** Line number */
  pos_lnum: number;
  /** Beginning of line offset */
  pos_bol: number;
}

export interface Location {
  /** Start position */
  loc_start: Position;
  /** End position */
  loc_end: Position;
}

export interface MimeVal {
  /** MIME type */
  mime_type: string;
  /** Data content */
  data: string;
}

export interface Output {
  /** Cell identifier */
  cell_id: number;
  /** Standard output */
  stdout: string;
  /** Standard error */
  stderr: string;
  /** OCaml pretty-printed output */
  caml_ppf: string;
  /** MIME values */
  mime_vals: MimeVal[];
}

export interface CompletionEntry {
  /** Completion name */
  name: string;
  /** Kind (Value, Module, Type, etc.) */
  kind: string;
  /** Description */
  desc: string;
  /** Additional info */
  info: string;
  /** Whether deprecated */
  deprecated: boolean;
}

export interface Completions {
  /** Cell identifier */
  cell_id: number;
  /** Completions data */
  completions: {
    /** Start position */
    from: number;
    /** End position */
    to: number;
    /** Completion entries */
    entries: CompletionEntry[];
  };
}

export interface Error {
  /** Error kind */
  kind: string;
  /** Error location */
  loc: Location;
  /** Main error message */
  main: string;
  /** Sub-messages */
  sub: string[];
  /** Error source */
  source: string;
}

export interface ErrorList {
  /** Cell identifier */
  cell_id: number;
  /** Errors */
  errors: Error[];
}

export interface TypeInfo {
  /** Type location */
  loc: Location;
  /** Type string */
  type_str: string;
  /** Tail position info */
  tail: string;
}

export interface TypesResult {
  /** Cell identifier */
  cell_id: number;
  /** Type information */
  types: TypeInfo[];
}

export interface EnvResult {
  /** Environment ID */
  env_id: string;
}

export interface OutputAt {
  /** Cell identifier */
  cell_id: number;
  /** Character position after phrase (pos_cnum) */
  loc: number;
  /** OCaml pretty-printed output for this phrase */
  caml_ppf: string;
  /** MIME values for this phrase */
  mime_vals: MimeVal[];
}

export interface OcamlWorkerOptions {
  /** Timeout in milliseconds (default: 30000) */
  timeout?: number;
  /** Callback for incremental output after each phrase */
  onOutputAt?: (output: OutputAt) => void;
}

export class OcamlWorker {
  /**
   * Create a new OCaml worker client.
   * @param workerUrl - URL to the worker script
   * @param options - Options
   */
  constructor(workerUrl: string, options?: OcamlWorkerOptions);

  /**
   * Initialize the worker.
   * @param config - Initialization configuration
   */
  init(config: InitConfig): Promise<void>;

  /**
   * Wait for the worker to be ready.
   */
  waitReady(): Promise<void>;

  /**
   * Evaluate OCaml code.
   * @param code - OCaml code to evaluate
   * @param envId - Environment ID (default: 'default')
   */
  eval(code: string, envId?: string): Promise<Output>;

  /**
   * Get completions at a position.
   * @param source - Source code
   * @param position - Cursor position (character offset)
   * @param envId - Environment ID (default: 'default')
   */
  complete(source: string, position: number, envId?: string): Promise<Completions>;

  /**
   * Get type information at a position.
   * @param source - Source code
   * @param position - Cursor position (character offset)
   * @param envId - Environment ID (default: 'default')
   */
  typeAt(source: string, position: number, envId?: string): Promise<TypesResult>;

  /**
   * Get errors for source code.
   * @param source - Source code
   * @param envId - Environment ID (default: 'default')
   */
  errors(source: string, envId?: string): Promise<ErrorList>;

  /**
   * Create a new execution environment.
   * @param envId - Environment ID
   */
  createEnv(envId: string): Promise<EnvResult>;

  /**
   * Destroy an execution environment.
   * @param envId - Environment ID
   */
  destroyEnv(envId: string): Promise<EnvResult>;

  /**
   * Terminate the worker.
   */
  terminate(): void;
}

export default OcamlWorker;

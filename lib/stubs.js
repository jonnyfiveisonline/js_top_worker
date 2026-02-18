//Provides: caml_unix_times
function caml_unix_times() {
  return 4.2
}

//Provides: ml_merlin_fs_exact_case_basename
function ml_merlin_fs_exact_case_basename(str) {
  return 0
}

//Provides: ml_merlin_fs_exact_case
function ml_merlin_fs_exact_case(str) {
  return str
}

//Provides: stub_sha512_init
function stub_sha512_init() {
  return 0
}

//Provides: caml_thread_initialize
function caml_thread_initialize() {
  return 0
}

//Provides: caml_sys_const_arch_amd64 const
function caml_sys_const_arch_amd64() {
  return 1
}

//Provides: caml_sys_const_arch_arm64 const
function caml_sys_const_arch_arm64() {
  return 0
}

// OxCaml domain TLS - single-domain JS environment, just use a global
var _tls_state = 0;
//Provides: caml_domain_tls_get
function caml_domain_tls_get() {
  return _tls_state;
}

//Provides: caml_domain_tls_set
function caml_domain_tls_set(v) {
  _tls_state = v;
  return 0;
}

//Provides: caml_ml_domain_index
function caml_ml_domain_index() {
  return 0;
}

//Provides: caml_make_local_vect
//Requires: caml_make_vect
function caml_make_local_vect(len, init) {
  return caml_make_vect(len, init);
}

// OxCaml blocking sync primitives - no-ops in single-threaded JS
//Provides: caml_blocking_mutex_new
function caml_blocking_mutex_new() {
  return 0;
}

//Provides: caml_blocking_mutex_lock
function caml_blocking_mutex_lock(_m) {
  return 0;
}

//Provides: caml_blocking_mutex_unlock
function caml_blocking_mutex_unlock(_m) {
  return 0;
}

//Provides: caml_blocking_condition_new
function caml_blocking_condition_new() {
  return 0;
}

//Provides: caml_blocking_condition_wait
function caml_blocking_condition_wait(_c, _m) {
  return 0;
}

//Provides: caml_blocking_condition_signal
function caml_blocking_condition_signal(_c) {
  return 0;
}

//Provides: caml_thread_yield
function caml_thread_yield() {
  return 0;
}

// Basement/capsule primitives - OxCaml specific
//Provides: basement_dynamic_supported
function basement_dynamic_supported() {
  return 0;
}

//Provides: basement_dynamic_make
function basement_dynamic_make(_v) {
  return _v;
}

//Provides: basement_dynamic_get
function basement_dynamic_get(_v) {
  return _v;
}

//Provides: basement_alloc_stack_bind
function basement_alloc_stack_bind(_stack, _f, _v) {
  return 0;
}


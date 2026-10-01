module_path=("$PWD/.test-brief-backend/zsh-root/usr/lib/x86_64-linux-gnu/zsh/5.9" $module_path)
source bin/fm-backend.sh
original_path=$PATH
print -r -- '$ source bin/fm-backend.sh; fm_backend_source herdr'
fm_backend_source herdr
source_rc=$?
print -r -- "source_rc=$source_rc"
whence -w fm_backend_herdr_capture
[[ "$PATH" == "$original_path" ]] || exit 1
print -r -- "PATH retained; dirname=$(command -v dirname)"
(( source_rc == 0 )) || exit 1
print -r -- '$ fm_backend_source bogus'
fm_backend_source bogus
unknown_rc=$?
print -r -- "unknown_rc=$unknown_rc"
(( unknown_rc != 0 )) || exit 1
print -r -- '$ fm_backend_source "tmux herdr"'
fm_backend_source 'tmux herdr'
multi_rc=$?
print -r -- "multi_token_rc=$multi_rc"
(( multi_rc != 0 )) || exit 1
# A real copied adapter with an absent required sibling must be refused before loading.
FM_BACKEND_LIB_DIR=$PWD/.test-brief-backend/missing-sibling
print -r -- '$ FM_BACKEND_LIB_DIR=<copy with absent composer library> fm_backend_source herdr'
fm_backend_source herdr
missing_rc=$?
print -r -- "missing_sibling_rc=$missing_rc"
(( missing_rc != 0 )) || exit 1

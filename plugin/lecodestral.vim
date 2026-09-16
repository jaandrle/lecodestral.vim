if exists('g:loaded_lecodestral')
	finish
endif
let g:loaded_lecodestral = 1
let g:lecodestral#version = '1.2.0'

if !has('patch-9.0.0067') || !has('textprop') || !has('job')
	echohl WarningMsg
	echom 'LeCodestral: needs Vim 9.0.0067+ with +textprop and +job'
	echohl None
	finish
endif

highlight default link LeCodestralGhost Comment
if empty(prop_type_get('lecodestral_ghost'))
	call prop_type_add('lecodestral_ghost', {'highlight': 'LeCodestralGhost'})
endif

augroup LeCodestral
	autocmd!
	" autocmd TextChangedI * call lecodestral#on_change()
	autocmd InsertEnter,CursorMovedI,CompleteChanged * call lecodestral#on_change()
	autocmd BufEnter  * if mode() =~# '^[iR]'|call lecodestral#on_change()|endif
	autocmd InsertLeave * call lecodestral#dismiss()
	autocmd BufLeave     * if mode() =~# '^[iR]'|call lecodestral#dismiss()|endif
augroup END

inoremap <silent> <Plug>(lecodestral-complete) <cmd>call lecodestral#complete()<cr>
inoremap <silent> <Plug>(lecodestral-accept) <c-g>u<cmd>call lecodestral#accept()<cr>
inoremap <silent> <Plug>(lecodestral-dismiss) <cmd>call lecodestral#dismiss()<cr>
inoremap <silent> <Plug>(lecodestral-cycle-suggestions) <cmd>call lecodestral#cycle(1)<cr>
inoremap <silent> <Plug>(lecodestral-cycle-suggestions-prev) <cmd>call lecodestral#cycle(-1)<cr>
inoremap <silent> <Plug>(lecodestral-cycle-context) <cmd>call lecodestral#cycle_context()<cr>

command! LeCodestralToggle call lecodestral#toggle()
command! LeCodestralToggleBuffer call lecodestral#toggle_buffer()
command! LeCodestralDismiss call lecodestral#dismiss()
command! LeCodestralStatus call lecodestral#status()

let s:dir = expand('<sfile>:h:h')
if getftime(s:dir . '/doc/lecodestral.txt') > getftime(s:dir . '/doc/tags')
  silent! execute 'helptags' fnameescape(s:dir . '/doc')
endif

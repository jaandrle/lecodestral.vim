let s:default_endpoint = 'https://api.mistral.ai/v1/fim/completions'

function! s:get(key, default) abort
	return get(g:, 'lecodestral_' . a:key, a:default)
endfunction

function! s:log(msg) abort
	if get(g:, 'lecodestral_debug', 0)
		call writefile([strftime('%H:%M:%S') . ' ' . a:msg], '/tmp/lecodestral.log', 'a')
	endif
endfunction

let s:popup = -1
function s:notify(msg, highlight= 'Pmenu') abort
	if (s:popup != -1)
		call popup_close(s:popup)
	endif
	let s:popup= popup_notification(
		\ [ a:msg ],
		\ #{
				\ title: 'LeCodestral',
				\ line: 'cursor-1',
				\ col: 'cursor-1',
				\ pos: 'botleft',
				\ flip: v:true,
				\ highlight: a:highlight,
				\ moved: 'any',
				\ time: 6000,
				\ border: [1, 1, 0, 1],
				\ borderchars: ['–', ' ', ' ', ' ', ' ', ' ', ' ', ' '],
				\ padding: [0, 0, 0, 0],
		\}
	\)
endfunction

let s:enabled_global = s:get('enabled', 1)
let s:ghost_lines = []
let s:ghost_choices = []
let s:ghost_idx = 0
let s:ghost_active = 0
let s:timer_id = -1
let s:cur_job = v:null
let s:job_chunks = []
let s:gen = 0
let s:req_lnum = 0
let s:req_col = 0
let s:req_buf = 0
let s:warned_key = 0
let s:context_options = ['preview', 'full', 'line', 'word']
let s:context = 'preview'
let s:statusline_active = 0

function! s:disabled_reason() abort
	if !s:enabled_global
		return 'disabled globally (LeCodestralToggle)'
	endif
	if &buftype =~# '^\%(help\|prompt\|quickfix\|terminal\|nofile\)$'
		return 'buftype=' . &buftype
	endif
	if exists('b:lecodestral_enabled')
		return b:lecodestral_enabled ? '' : 'b:lecodestral_enabled = 0'
	endif
	let l:short = empty(&filetype) ? '.' : &filetype->split('\.', 1)[0]
	let l:config = s:get('disabled_filetypes', [])
	if l:config->index(&filetype) >= 0 || l:config->index(l:short) >= 0
		return 'disabled filetype:' . &filetype
	endif
	return ''
endfunction
function! s:is_enabled() abort
	return empty(s:disabled_reason())
endfunction

function! lecodestral#statusline() abort
	let s:statusline_active = 1
	let l:reason = s:disabled_reason()
	if !empty(l:reason)
		return 'OFF'
	endif
	if mode() !~# '^[iRc]'
		return ' ON'
	endif
	if type(s:cur_job) == v:t_job && job_status(s:cur_job) ==# 'run'
		return ' * '
	endif
	if !empty(s:ghost_choices)
		return printf('%d/%d', s:ghost_idx + 1, len(s:ghost_choices))
	endif
	return ' 0 '
endfunction

function! s:redraw_statusline() abort
	if s:statusline_active
		redrawstatus
	endif
endfunction

function! lecodestral#status() abort
	let l:reason = s:disabled_reason()
	if !empty(l:reason)
		call s:notify('Disabled: ' . l:reason)
	else
		call s:notify('Enabled (' . (type(s:cur_job) == v:t_job && job_status(s:cur_job) ==# 'run' ? 'request in flight' : 'idle') . ')')
	endif
endfunction

function! s:clear_ghost() abort
	if s:ghost_active
		silent! call prop_remove({'type': 'lecodestral_ghost', 'all': v:true}, 1, line('$'))
		let s:ghost_lines = []
		let s:ghost_active = 0
		call s:redraw_statusline()
	endif
endfunction

function! s:render_ghost(lines) abort
	call s:clear_ghost()
	if empty(a:lines) || (len(a:lines) == 1 && a:lines[0] ==# '')
		return
	endif
	let l:lnum = line('.')
	let l:curlen = strlen(getline(l:lnum))
	let l:c = col('.')
	if l:c > l:curlen
		call prop_add(l:lnum, 0, {'type': 'lecodestral_ghost', 'text': a:lines[0], 'text_align': 'after'})
	else
		call prop_add(l:lnum, l:c, {'type': 'lecodestral_ghost', 'text': a:lines[0]})
	endif
	for l:extra in a:lines[1:]
		call prop_add(l:lnum, 0, {'type': 'lecodestral_ghost', 'text': l:extra, 'text_align': 'below'})
	endfor
	let s:ghost_lines = a:lines
	let s:ghost_active = 1
	call s:redraw_statusline()
endfunction

" Checks whether the text the user just typed (since the anchor col/lnum of
" the currently displayed ghost) is an exact byte-prefix of the ghost's
" first line. If so, shrinks the ghost in place instead of clearing it.
" Returns one of:
"		'no-ghost'	— no ghost was active, caller should behave as before
"		'matched'		— typed text consumed (partially or fully, with lines left);
"									a shrunk ghost is now rendered, caller must not re-trigger
"		'exhausted' — typed text consumed the entire remaining suggestion;
"									ghost cleared, caller may re-trigger
"		'diverged'	— typed text left the anchor or no longer matches;
"									ghost cleared, caller may re-trigger
function! s:consume_typed_prefix() abort
	if !s:ghost_active
		return 'no-ghost'
	endif
	if bufnr('%') != s:req_buf || line('.') != s:req_lnum
		call s:clear_ghost()
		return 'diverged'
	endif
	let l:col = col('.')
	if l:col < s:req_col
		call s:clear_ghost()
		return 'diverged'
	endif
	let l:typed = strpart(getline('.'), s:req_col - 1, l:col - s:req_col)
	if l:typed ==# ''
		call s:clear_ghost()
		return 'diverged'
	endif
	let l:first = s:ghost_lines[0]
	if stridx(l:first, l:typed) != 0
		call s:clear_ghost()
		return 'diverged'
	endif
	if l:typed ==# l:first
		if len(s:ghost_lines) > 1
			let s:ghost_lines = s:ghost_lines[1:]
			let s:ghost_choices = [s:ghost_lines]
			let s:ghost_idx = 0
			let s:req_lnum = line('.')
			let s:req_col = l:col
			call s:render_ghost(s:ghost_lines)
			return 'matched'
		endif
		call s:clear_ghost()
		return 'exhausted'
	endif
	let s:ghost_lines[0] = strpart(l:first, strlen(l:typed))
	let s:ghost_choices = [s:ghost_lines]
	let s:ghost_idx = 0
	let s:req_col = l:col
	call s:render_ghost(s:ghost_lines)
	return 'matched'
endfunction

function! s:on_out(gen, ch, msg) abort
	if a:gen != s:gen
		return
	endif
	call add(s:job_chunks, a:msg)
endfunction

function! lecodestral#cycle_context() abort
	let l:ghost_lines_len = s:ghost_lines->len()
	if l:ghost_lines_len > 1
		let l:curr = s:context_options->index(s:context)
		let l:idx = (l:curr + 1) % len(s:context_options)
		if l:ghost_lines_len < s:get('max_lines', 3)
			let l:idx += 1
		endif
		let s:context = s:context_options[l:idx]
	else 
		let s:context = s:context ==# 'word' ? 'preview' : 'word'
	endif
	call lecodestral#cycle(0)
endfunction

function! lecodestral#cycle(offset) abort
	" Cycle to next/prev suggestion (offset +1 or -1). Returns 0 on success.
	if empty(s:ghost_choices)
		call s:notify('No suggestions')
		return 1
	endif
	let l:n = len(s:ghost_choices)
	let s:ghost_idx = (s:ghost_idx + a:offset + l:n) % l:n
	let l:maxl = s:context ==# 'full' ? -1 : (s:context ==# 'preview' ? s:get('max_lines', 3) : 1)
	let l:lines = s:ghost_choices[s:ghost_idx]
	if l:maxl > 0
		let l:lines = l:lines[0 : min([l:maxl, l:lines->len()]) - 1]
	endif
	if s:context ==# 'word'
		let l:end = l:lines[0]->matchend('\%(\k\@!.\)*\k*')
		let l:lines = [l:lines[0]->strpart(0, l:end)]
	endif
	call s:render_ghost(l:lines)
	let l:context_text = s:context ==# 'preview' ? 'max '.s:get('max_lines', 3).' lines' : s:context
	call s:notify('Suggestion ' . (s:ghost_idx + 1) . '/' . l:n . ' (' . l:context_text . ')')
	return 0
endfunction

function! s:on_err(gen, ch, msg) abort
	call s:log('ERR ' . a:msg)
endfunction

" Strip from the last suggestion line the longest suffix that is also a
" prefix of the text after the cursor on the current line. FIM models
" sometimes echo part of the suffix; this prevents duplicated text on
" accept and avoids a doubled ghost display.
function! s:strip_suffix_overlap(lines) abort
	if empty(a:lines)
		return a:lines
	endif
	let l:after = strpart(getline('.'), col('.') - 1)
	if l:after ==# ''
		return a:lines
	endif
	let l:last = a:lines[-1]
	if l:last ==# ''
		return a:lines
	endif
	let l:max = min([strlen(l:last), strlen(l:after)])
	for l:len in range(l:max, 1, -1)
		if strpart(l:last, strlen(l:last) - l:len) ==# strpart(l:after, 0, l:len)
			let l:result = copy(a:lines)
			let l:result[-1] = strpart(l:last, 0, strlen(l:last) - l:len)
			return l:result
		endif
	endfor
	return a:lines
endfunction

function! s:finish(gen, ch) abort
	call s:redraw_statusline()
	let s:ghost_choices = []
	let s:ghost_idx = 0
	if a:gen != s:gen
		call s:log('bail: stale job gen=' . a:gen . ' cur=' . s:gen)
		return
	endif
	call s:log('finish chunks=' . len(s:job_chunks))
	if bufnr('%') != s:req_buf || line('.') != s:req_lnum || col('.') != s:req_col
		call s:log('bail: cursor moved (buf/lnum/col mismatch)')
		return
	endif
	if mode() !~# '^[iRc]'
		call s:log('bail: not insert mode (' . mode() . ')')
		return
	endif
	let l:raw = join(s:job_chunks, '')
	if l:raw ==# ''
		call s:log('bail: empty response')
		return
	endif
	try
		let l:data = json_decode(l:raw)
	catch
		call s:log('bail: json_decode failed: ' . v:exception . ' raw=' . l:raw[0:300])
		return
	endtry
	if type(l:data) != v:t_dict || !has_key(l:data, 'choices') || empty(l:data.choices)
		call s:log('bail: no choices. raw=' . l:raw[0:300])
		return
	endif
	let l:texts = []
	for l:choice in l:data.choices
		let l:text = ''
		if has_key(l:choice, 'message') && type(l:choice.message) == v:t_dict && has_key(l:choice.message, 'content')
			let l:text = l:choice.message.content
		elseif has_key(l:choice, 'text')
			let l:text = l:choice.text
		endif
		if l:text ==# '' || l:texts->index(l:text) >= 0
			continue
		endif
		call add(l:texts, l:text)
		let l:lines = s:strip_suffix_overlap(split(l:text, "\n", 1))
		call add(s:ghost_choices, l:lines)
	endfor
	if empty(s:ghost_choices)
		return
	endif
	call lecodestral#cycle(0)
endfunction

function! s:trigger(...) abort
	let s:timer_id = -1
	if &encoding !=# 'latin1' && &encoding !=# 'utf-8'
		call s:log('bail: unsupported encoding ' . &encoding)
		return
	endif
	if !s:is_enabled() || mode() !~# '^[iRc]'
		return
	endif
	call s:log('trigger fired')
	let l:env = s:get('api_key_env', 'CODESTRAL_API_KEY')
	let l:key = getenv(l:env)
	if type(l:key) != v:t_string || l:key ==# ''
		call s:log('bail: env ' . l:env . ' not set in Vim')
		if !s:warned_key
			let s:warned_key = 1
			call s:notify('Environment variable `' . l:env . '` not set', 'WarningMsg')
		endif
		return
	endif
	if type(s:cur_job) == v:t_job && job_status(s:cur_job) ==# 'run'
		call job_stop(s:cur_job)
	endif

	let l:lnum = line('.')
	let l:c = col('.')
	let s:req_lnum = l:lnum
	let s:req_col = l:c
	let s:req_buf = bufnr('%')

	let l:all = getline(1, '$')
	let l:cur = l:all[l:lnum - 1]
	let l:before_cur = strpart(l:cur, 0, l:c - 1)
	let l:after_cur = strpart(l:cur, l:c - 1)

	let l:prefix = ''
	if l:lnum > 1
		let l:prefix = join(l:all[0 : l:lnum - 2], "\n") . "\n"
	endif
	let l:prefix .= l:before_cur

	let l:suffix = l:after_cur
	if l:lnum < len(l:all)
		let l:suffix .= "\n" . join(l:all[l:lnum :], "\n")
	endif

	let l:maxp = s:get('max_prefix', 8000)
	let l:maxs = s:get('max_suffix', 4000)
	if strlen(l:prefix) > l:maxp
		let l:prefix = strpart(l:prefix, strlen(l:prefix) - l:maxp)
		let l:nl = stridx(l:prefix, "\n")
		if l:nl >= 0
			let l:prefix = strpart(l:prefix, l:nl + 1)
		endif
	endif
	if strlen(l:suffix) > l:maxs
		let l:suffix = strpart(l:suffix, 0, l:maxs)
		let l:nl = strridx(l:suffix, "\n")
		if l:nl >= 0
			let l:suffix = strpart(l:suffix, 0, l:nl)
		endif
	endif

	let l:payload = {
				\ 'model': s:get('model', 'codestral-latest'),
				\ 'prompt': l:prefix,
				\ 'suffix': l:suffix,
				\ 'max_tokens': s:get('max_tokens', 256),
				\ 'temperature': s:get('temperature', 0.2),
				\ 'stream': v:false,
				\ 'n': s:get('choices', 3),
				\ }
	let l:stop = s:get('stop', ["\n\n\n"])
	if type(l:stop) == v:t_list && !empty(l:stop)
		let l:payload.stop = l:stop
	endif
	let l:body = json_encode(l:payload)

	let l:argv = ['curl', '-s', '-X', 'POST', s:get('endpoint', s:default_endpoint),
				\ '-H', 'Content-Type: application/json',
				\ '-H', 'Authorization: Bearer ' . l:key,
				\ '-d', l:body]

	call s:log('POST body=' . strlen(l:body) . 'B prefix=' . strlen(l:prefix) . ' suffix=' . strlen(l:suffix))
	let s:gen += 1
	let l:gen = s:gen
	let s:job_chunks = []
	let s:cur_job = job_start(l:argv, {
				\ 'out_mode': 'raw',
				\ 'out_cb': function('s:on_out', [l:gen]),
				\ 'err_cb': function('s:on_err', [l:gen]),
				\ 'close_cb': function('s:finish', [l:gen]),
				\ })
	call s:redraw_statusline()
endfunction

function! lecodestral#on_change() abort
	if !s:is_enabled()
		return
	endif
	let l:result = s:consume_typed_prefix()
	if l:result ==# 'matched'
		if s:timer_id != -1
			call timer_stop(s:timer_id)
			let s:timer_id = -1
		endif
		return
	endif
	return lecodestral#complete()
endfunction
" Trigger completion (force if not enabled?)
function! lecodestral#complete() abort
	call s:clear_ghost()
	if s:timer_id != -1
		call timer_stop(s:timer_id)
	endif
	let s:timer_id = timer_start(s:get('debounce_ms', 150), function('s:trigger'))
endfunction

function! lecodestral#dismiss() abort
	call s:clear_ghost()
	let s:ghost_choices = []
	let s:ghost_idx = 0
	let s:context = 'preview'
endfunction

function! lecodestral#toggle() abort
	let s:enabled_global = !s:enabled_global
	if !s:enabled_global
		call s:clear_ghost()
	endif
	call s:notify(s:enabled_global ? 'Enabled' : 'Disabled')
	call s:redraw_statusline()
endfunction
function! lecodestral#toggle_buffer() abort
	let b:lecodestral_enabled = !get(b:, 'lecodestral_enabled', 1)
	if !b:lecodestral_enabled
		call s:clear_ghost()
	endif
	call s:notify('Buffer ' . (b:lecodestral_enabled ? 'enabled' : 'disabled'))
	call s:redraw_statusline()
endfunction

function! lecodestral#accept() abort
	if empty(s:ghost_choices) && !s:ghost_active
		if pumvisible()
			call feedkeys("\<C-n>", 'n')
		else
			call feedkeys("\<Tab>", 'n')
		endif
		return
	endif
	let l:lines = s:ghost_lines
	call s:clear_ghost()
	let s:context = 'preview'
	let l:lnum = line('.')
	let l:c = col('.')
	let l:cur = getline(l:lnum)
	let l:before = strpart(l:cur, 0, l:c - 1)
	let l:after = strpart(l:cur, l:c - 1)
	if len(l:lines) == 1
		call setline(l:lnum, l:before . l:lines[0] . l:after)
		call cursor(l:lnum, strlen(l:before . l:lines[0]) + 1)
	else
		call setline(l:lnum, l:before . l:lines[0])
		let l:lines[-1] = l:lines[-1] . l:after
		call append(l:lnum, l:lines[1:])
		let l:endlnum = l:lnum + len(l:lines) - 1
		call cursor(l:endlnum, strlen(l:lines[-1]) - strlen(l:after) + 1)
	endif
endfunction

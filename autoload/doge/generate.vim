let s:save_cpo = &cpoptions
set cpoptions&vim

let s:comment_placeholder = doge#helpers#placeholder()

""
" @public
" Generates a comment based on a given pattern.
function! doge#generate#pattern(pattern) abort
  " Assuming multiline function expressions won't be longer than 15 lines.
  let l:lines_raw = getline('.', line('.') + 15)
  let l:lines = map(l:lines_raw, { key, line ->
        \ substitute(line, b:doge_pattern_single_line_comment, '' ,'g') })

  " Skip if the cursor doesn't start with text.
  if empty(doge#helpers#trim(l:lines[0]))
    return 0
  endif

  " Check if a generator is available. Otherwise we do a fallback on the regex.
  let l:use_generator = has_key(a:pattern, 'generator')
  if l:use_generator
    let l:tokens = doge#helpers#generator(a:pattern['generator'])
    if type(l:tokens) != v:t_dict
      return 0
    endif
  else
    " Skip if the current line does not match the main pattern.
    let l:curr_line_raw = escape(doge#helpers#trim(join(l:lines, ' ')), '\')
    if l:curr_line_raw !~# a:pattern['match']
      return 0
    endif

    " Remove comments to ensure we can match
    " our patterns with and without comments.
    let l:curr_line = substitute(
          \ l:curr_line_raw,
          \ b:doge_pattern_multi_line_comment,
          \ '',
          \ 'g'
          \ )

    " Extract the primary tokens.
    let l:tokens = doge#token#extract(
          \ l:curr_line,
          \ a:pattern['match'],
          \ a:pattern['match_group_names']
          \ )[0]
  endif

  try
    let l:preprocess_fn = printf('doge#preprocessors#%s#tokens', &filetype)
    call function(l:preprocess_fn)(l:tokens)
  catch /^Vim\%((\a\+)\)\=:E117/
  endtry

  " Split the 'parameters' token value into a list.
  if has_key(a:pattern, 'parameters') && has_key(l:tokens, 'parameters')
    let l:params_dict = a:pattern['parameters']
    let l:params = l:tokens['parameters']

    " Go through each parameter, match the regex, extract the token values and
    " replace the 'parameters' key with the formatted version.
    let l:formatted_params = []

    let l:param_tokens = l:use_generator ? l:params : doge#token#extract(
          \ l:params,
          \ l:params_dict['match'],
          \ l:params_dict['match_group_names']
          \ )

    " Preprocess the extracted parameter tokens.
    try
      let l:preprocess_fn = printf('doge#preprocessors#%s#parameter_tokens', &filetype)
      call function(l:preprocess_fn)(l:param_tokens)
    catch /^Vim\%((\a\+)\)\=:E117/
    endtry

    for l:param_token in l:param_tokens
      let l:format_doc_standard = has_key(l:params_dict['format'], b:doge_doc_standard)
            \ ? l:params_dict['format'][b:doge_doc_standard]
            \ : l:params_dict['format'][b:doge_supported_doc_standards[0]]
      let l:format = doge#token#replace(
            \ l:param_token,
            \ l:format_doc_standard
            \ )
      if type(l:format) == v:t_list
        call add(l:formatted_params, join(l:format, "\n"))
      else
        call add(l:formatted_params, l:format)
      endif
    endfor
    let l:tokens['parameters'] = l:formatted_params
  endif

  " Create the comment by replacing the tokens in the template with their
  " corresponding values.
  let l:comment = []
  let l:comment_template_doc_standard = has_key(a:pattern['comment']['template'], b:doge_doc_standard)
        \ ? a:pattern['comment']['template'][b:doge_doc_standard]
        \ : a:pattern['comment']['template'][b:doge_supported_doc_standards[0]]
  for l:line in l:comment_template_doc_standard
    " If empty lines are present, just append them to ensure a whiteline is
    " inserted rather then completely removed. This allows us to insert some
    " whitelines in the comment template.
    let l:line_replaced = doge#token#replace(l:tokens, l:line)
    if empty(l:line) || empty(l:line_replaced)
      call add(l:comment, '')
      continue
    elseif l:line_replaced ==# '-'
      continue
    endif

    for l:replaced in split(l:line_replaced, "\n")
      call add(l:comment, substitute(l:replaced, '\C\\t', repeat(' ', shiftwidth()), 'g'))
    endfor
  endfor

  if a:pattern['comment']['insert'] ==# 'below'
    let l:comment_lnum_insert_position = line('.')
    let l:comment_lnum_inherited_indent = line('.') + 1
  else
    let l:comment_lnum_inherited_indent = line('.')
    let l:comment_lnum_insert_position = line('.') - 1
  endif

  try
    let l:preprocess_fn = printf('doge#preprocessors#%s#insert_position', &filetype)
    let l:preprocessed_insert_position = function(l:preprocess_fn)(l:comment_lnum_insert_position)
    let l:comment_lnum_insert_position = l:preprocessed_insert_position

    " Update the inherited_indent variable based on the new insert position.
    " For now we only have to do this for languages like Python where we insert
    " below the declaration.
    if a:pattern['comment']['insert'] ==# 'below'
      let l:comment_lnum_inherited_indent = l:comment_lnum_insert_position + 1
    endif
  catch /^Vim\%((\a\+)\)\=:E117/
  endtry

  " vint: next-line -ProhibitUnusedVariable
  let l:Indent = function('doge#indent#add', [l:comment_lnum_inherited_indent])

  " Indent the comment.
  let l:comment = map(l:comment, { k, line -> l:Indent(line) })

  " Write the comment.
  call append(l:comment_lnum_insert_position, l:comment)

  " Enable interactive mode.
  if g:doge_comment_interactive == v:true
    if a:pattern['comment']['insert'] ==# 'below'
      let l:todo_match = search(s:comment_placeholder, 'nW', l:comment_lnum_insert_position + len(l:comment))
    else
      let l:todo_match = search(s:comment_placeholder, 'bnW', l:comment_lnum_insert_position + 1)
    endif
    if l:todo_match != 0
      let l:todo_count = doge#helpers#count(
            \ s:comment_placeholder,
            \ (l:comment_lnum_insert_position + 1),
            \ (l:comment_lnum_insert_position + len(l:comment))
            \ )
      if l:todo_count > 0
        let b:doge_interactive = {
              \ 'comment': l:comment,
              \ 'lnum_comment_start_pos': (l:comment_lnum_insert_position + 1),
              \ 'lnum_comment_end_pos': (l:comment_lnum_insert_position + len(l:comment)),
              \ }
        " Go to the top of the comment and select the first TODO.
        exe l:comment_lnum_insert_position + 1
        call search(s:comment_placeholder, 'W')
        call execute("normal! gno\<C-g>")
      endif
    endif
  endif

  " Return 1 to indicate we have succesfully inserted the comment.
  return 1
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo

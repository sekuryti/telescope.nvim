local from_entry = require('telescope.from_entry')
local path = require('telescope.path')
local utils = require('telescope.utils')
local putils = require('telescope.previewers.utils')
local Previewer = require('telescope.previewers.previewer')
local conf = require('telescope.config').values

local pfiletype = require('plenary.filetype')
local pscan = require('plenary.scandir')

local buf_delete = utils.buf_delete
local defaulter = utils.make_default_callable

local previewers = {}

local ns_previewer = vim.api.nvim_create_namespace('telescope.previewers')

previewers.file_maker = function(filepath, bufnr, opts)
  opts = opts or {}
  if opts.use_ft_detect == nil then opts.use_ft_detect = true end
  local ft = opts.use_ft_detect and pfiletype.detect(filepath)

  if opts.bufname ~= filepath then
    filepath = vim.fn.expand(filepath)
    local stat = vim.loop.fs_stat(filepath) or {}
    if stat.type == 'directory' then
      pscan.ls_async(filepath, { hidden = true, on_exit = vim.schedule_wrap(function(data)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, data)
        if opts.callback then opts.callback(bufnr) end
      end)})
    else
      path.read_file_async(filepath, vim.schedule_wrap(function(data)
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        local ok = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, vim.split(data, '[\r]?\n'))
        if not ok then return end

        if opts.callback then opts.callback(bufnr) end
        putils.highlighter(bufnr, ft)
      end))
    end
  else
    if opts.callback then opts.callback(bufnr) end
  end
end

previewers.new_buffer_previewer = function(opts)
  opts = opts or {}

  assert(opts.define_preview, "define_preview is a required function")
  assert(not opts.preview_fn, "preview_fn not allowed")

  local opt_setup = opts.setup
  local opt_teardown = opts.teardown

  local old_bufs = {}
  local bufname_table = {}

  local global_state = require'telescope.state'
  local preview_window_id

  local function get_bufnr(self)
    if not self.state then return nil end
    return self.state.bufnr
  end

  local function set_bufnr(self, value)
    if get_bufnr(self) then table.insert(old_bufs, get_bufnr(self)) end
    if self.state then self.state.bufnr = value end
  end

  local function get_bufnr_by_bufname(self, value)
    if not self.state then return nil end
    return bufname_table[value]
  end

  local function set_bufname(self, value)
    if get_bufnr(self) then bufname_table[value] = get_bufnr(self) end
    if self.state then self.state.bufname = value end
  end

  function opts.setup(self)
    local state = {}
    if opt_setup then vim.tbl_deep_extend("force", state, opt_setup(self)) end
    return state
  end

  function opts.teardown(self)
    if opt_teardown then
      opt_teardown(self)
    end

    local last_nr
    if opts.keep_last_buf then
      last_nr = global_state.get_global_key('last_preview_bufnr')
      -- Push in another buffer so the last one will not be cleaned up
      if preview_window_id then
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(preview_window_id, bufnr)
      end
    end

    set_bufnr(self, nil)
    set_bufname(self, nil)

    for _, bufnr in ipairs(old_bufs) do
      if bufnr ~= last_nr then
        buf_delete(bufnr)
      end
    end
  end

  function opts.preview_fn(self, entry, status)
    if get_bufnr(self) == nil then
      set_bufnr(self, vim.api.nvim_win_get_buf(status.preview_win))
      preview_window_id = status.preview_win
    end

    if opts.get_buffer_by_name and get_bufnr_by_bufname(self, opts.get_buffer_by_name(self, entry)) then
      self.state.bufname = opts.get_buffer_by_name(self, entry)
      self.state.bufnr = get_bufnr_by_bufname(self, self.state.bufname)
      vim.api.nvim_win_set_buf(status.preview_win, self.state.bufnr)
    else
      local bufnr = vim.api.nvim_create_buf(false, true)
      set_bufnr(self, bufnr)

      vim.api.nvim_win_set_buf(status.preview_win, bufnr)

      -- TODO(conni2461): We only have to set options once. Right?
      vim.api.nvim_win_set_option(status.preview_win, 'winhl', 'Normal:TelescopePreviewNormal')
      vim.api.nvim_win_set_option(status.preview_win, 'signcolumn', 'no')
      vim.api.nvim_win_set_option(status.preview_win, 'foldlevel', 100)
      vim.api.nvim_win_set_option(status.preview_win, 'wrap', false)

      self.state.winid = status.preview_win
      self.state.bufname = nil
    end

    if opts.keep_last_buf then global_state.set_global_key("last_preview_bufnr", self.state.bufnr) end

    opts.define_preview(self, entry, status)

    putils.with_preview_window(status, nil, function()
      vim.cmd'do User TelescopePreviewerLoaded'
    end)

    if opts.get_buffer_by_name then
      set_bufname(self, opts.get_buffer_by_name(self, entry))
    end
  end

  if not opts.scroll_fn then
    function opts.scroll_fn(self, direction)
      if not self.state then return end

      local input = direction > 0 and [[]] or [[]]
      local count = math.abs(direction)

      vim.api.nvim_buf_call(self.state.bufnr, function()
        vim.cmd([[normal! ]] .. count .. input)
      end)
    end
  end

  return Previewer:new(opts)
end

previewers.cat = defaulter(function(_)
  return previewers.new_buffer_previewer {
    get_buffer_by_name = function(_, entry)
      return from_entry.path(entry, true)
    end,

    define_preview = function(self, entry, status)
      local p = from_entry.path(entry, true)
      if p == nil or p == '' then return end
      conf.buffer_previewer_maker(p, self.state.bufnr, {
        bufname = self.state.bufname
      })
    end
  }
end, {})

previewers.vimgrep = defaulter(function(_)
  local jump_to_line = function(self, bufnr, lnum)
    if lnum and lnum > 0 then
      pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_previewer, "TelescopePreviewLine", lnum - 1, 0, -1)
      pcall(vim.api.nvim_win_set_cursor, self.state.winid, {lnum, 0})
      vim.api.nvim_buf_call(bufnr, function() vim.cmd"norm! zz" end)
    end

    self.state.last_set_bufnr = bufnr
  end

  return previewers.new_buffer_previewer {
    setup = function()
      return {
        last_set_bufnr = nil
      }
    end,

    teardown = function(self)
      if self.state and self.state.last_set_bufnr and vim.api.nvim_buf_is_valid(self.state.last_set_bufnr) then
        vim.api.nvim_buf_clear_namespace(self.state.last_set_bufnr, ns_previewer, 0, -1)
      end
    end,

    get_buffer_by_name = function(_, entry)
      return from_entry.path(entry, true)
    end,

    define_preview = function(self, entry, status)
      local p = from_entry.path(entry, true)
      if p == nil or p == '' then return end

      if self.state.last_set_bufnr then
        pcall(vim.api.nvim_buf_clear_namespace, self.state.last_set_bufnr, ns_previewer, 0, -1)
      end

      -- Workaround for unnamed buffer when using builtin.buffer
      if entry.bufnr and (p == '[No Name]' or vim.api.nvim_buf_get_option(entry.bufnr, 'buftype') ~= '') then
        local lines = vim.api.nvim_buf_get_lines(entry.bufnr, 0, -1, false)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        jump_to_line(self, self.state.bufnr, entry.lnum)
      else
        conf.buffer_previewer_maker(p, self.state.bufnr, {
          bufname = self.state.bufname,
          callback = function(bufnr) jump_to_line(self, bufnr, entry.lnum) end
        })
      end
    end
  }
end, {})

previewers.qflist = previewers.vimgrep

previewers.ctags = defaulter(function(_)
  local determine_jump = function(entry)
    if entry.scode then
      return function(self)
        local scode = string.gsub(entry.scode, '[$]$', '')
        scode = string.gsub(scode, [[\\]], [[\]])
        scode = string.gsub(scode, [[\/]], [[/]])
        scode = string.gsub(scode, '[*]', [[\*]])

        pcall(vim.fn.matchdelete, self.state.hl_id, self.state.winid)
        vim.cmd "norm! gg"
        vim.fn.search(scode, "W")
        vim.cmd "norm! zz"

        self.state.hl_id = vim.fn.matchadd('TelescopePreviewMatch', scode)
      end
    else
      return function(self, bufnr)
        if self.state.last_set_bufnr then
          pcall(vim.api.nvim_buf_clear_namespace, self.state.last_set_bufnr, ns_previewer, 0, -1)
        end
        pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_previewer, "TelescopePreviewMatch", entry.lnum - 1, 0, -1)
        pcall(vim.api.nvim_win_set_cursor, self.state.winid, { entry.lnum, 0 })
        self.state.last_set_bufnr = bufnr
      end
    end
  end

  return previewers.new_buffer_previewer {
    teardown = function(self)
      if self.state and self.state.hl_id then
        pcall(vim.fn.matchdelete, self.state.hl_id, self.state.hl_win)
        self.state.hl_id = nil
      elseif self.state and self.state.last_set_bufnr and vim.api.nvim_buf_is_valid(self.state.last_set_bufnr) then
        vim.api.nvim_buf_clear_namespace(self.state.last_set_bufnr, ns_previewer, 0, -1)
      end
    end,

    get_buffer_by_name = function(_, entry)
      return entry.filename
    end,

    define_preview = function(self, entry, status)
      conf.buffer_previewer_maker(entry.filename, self.state.bufnr, {
        bufname = self.state.bufname,
        callback = function(bufnr)
          vim.api.nvim_buf_call(bufnr, function()
            determine_jump(entry)(self, bufnr)
          end)
        end
      })
    end
  }
end, {})

previewers.builtin = defaulter(function(_)
  return previewers.new_buffer_previewer {
    setup = function()
      return {}
    end,

    teardown = function(self)
      if self.state and self.state.hl_id then
        pcall(vim.fn.matchdelete, self.state.hl_id, self.state.hl_win)
        self.state.hl_id = nil
      end
    end,

    get_buffer_by_name = function(_, entry)
      return entry.filename
    end,

    define_preview = function(self, entry, status)
      local module_name = vim.fn.fnamemodify(entry.filename, ':t:r')
      local text
      if entry.text:sub(1, #module_name) ~= module_name then
        text = module_name .. '.' .. entry.text
      else
        text = entry.text:gsub('_', '.', 1)
      end

      conf.buffer_previewer_maker(entry.filename, self.state.bufnr, {
        bufname = self.state.bufname,
        callback = function(bufnr)
          vim.api.nvim_buf_call(bufnr, function()
            pcall(vim.fn.matchdelete, self.state.hl_id, self.state.winid)
            vim.cmd "norm! gg"
            vim.fn.search(text, "W")
            vim.cmd "norm! zz"

            self.state.hl_id = vim.fn.matchadd('TelescopePreviewMatch', text)
          end)
        end
      })
    end
  }
end, {})

previewers.help = defaulter(function(_)
  return previewers.new_buffer_previewer {
    setup = function()
      return {}
    end,

    teardown = function(self)
      if self.state and self.state.hl_id then
        pcall(vim.fn.matchdelete, self.state.hl_id, self.state.hl_win)
        self.state.hl_id = nil
      end
    end,

    get_buffer_by_name = function(_, entry)
      return entry.filename
    end,

    define_preview = function(self, entry, status)
      local query = entry.cmd
      query = query:sub(2)
      query = [[\V]] .. query

      conf.buffer_previewer_maker(entry.filename, self.state.bufnr, {
        bufname = self.state.bufname,
        callback = function(bufnr)
          vim.api.nvim_buf_call(bufnr, function()
            vim.cmd(':ownsyntax help')

            pcall(vim.fn.matchdelete, self.state.hl_id, self.state.winid)
            vim.cmd "norm! gg"
            vim.fn.search(query, "W")
            vim.cmd "norm! zz"

            self.state.hl_id = vim.fn.matchadd('TelescopePreviewMatch', query)
          end)
        end
      })
    end
  }
end, {})

previewers.man = defaulter(function(opts)
  local pager = utils.get_lazy_default(opts.PAGER, function()
    return vim.fn.executable('col') == 1 and 'col -bx' or ''
  end)
  return previewers.new_buffer_previewer {
    get_buffer_by_name = function(_, entry)
      return entry.value
    end,

    define_preview = function(self, entry, status)
      local win_width = vim.api.nvim_win_get_width(self.state.winid)
      putils.job_maker({'man', entry.section, entry.value}, self.state.bufnr, {
        env = { ["PAGER"] = pager, ["MANWIDTH"] = win_width },
        value = entry.value,
        bufname = self.state.bufname
      })
      putils.regex_highlighter(self.state.bufnr, 'man')
    end
  }
end)

previewers.git_branch_log = defaulter(function(_)
  local highlight_buffer = function(bufnr, content)
    for i = 1, #content do
      local line = content[i]
      local _, hstart = line:find('[%*%s|]*')
      if hstart then
        local hend = hstart + 7
        if hend < #line then
          vim.api.nvim_buf_add_highlight(bufnr, ns_previewer, "TelescopeResultsIdentifier", i - 1, hstart - 1, hend)
        end
      end
      local _, cstart = line:find('- %(')
      if cstart then
        local cend = string.find(line, '%) ')
        if cend then
          vim.api.nvim_buf_add_highlight(bufnr, ns_previewer, "TelescopeResultsConstant", i - 1, cstart - 1, cend)
        end
      end
      local dstart, _ = line:find(' %(%d')
      if dstart then
        vim.api.nvim_buf_add_highlight(bufnr, ns_previewer, "TelescopeResultsSpecialComment", i - 1, dstart, #line)
      end
    end
  end

  local remotes = utils.get_os_command_output{ 'git', 'remote' }
  return previewers.new_buffer_previewer {
    get_buffer_by_name = function(_, entry)
      return entry.value
    end,

    define_preview = function(self, entry, status)
      local current_remote = 1

      local gen_cmd = function(v)
        return { 'git', '-P', 'log', '--graph', '--pretty=format:%h -%d %s (%cr)',
        '--abbrev-commit', '--date=relative', v }
      end

      local handle_results
      handle_results = function(bufnr, content)
        if content and table.getn(content) == 0 then
          if current_remote <= table.getn(remotes) then
            local value = 'remotes/' .. remotes[current_remote] .. '/' .. entry.value
            current_remote = current_remote + 1
            putils.job_maker(gen_cmd(value), bufnr, { callback = handle_results })
          else
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "No log found for branch: " .. entry.value })
          end
        elseif content and table.getn(content) > 1 then
          highlight_buffer(bufnr, content)
        end
      end

      putils.job_maker(gen_cmd(entry.value), self.state.bufnr, {
        value = entry.value,
        bufname = self.state.bufname,
        callback = handle_results
      })
    end
  }
end, {})

previewers.git_commit_diff = defaulter(function(_)
  return previewers.new_buffer_previewer {
    get_buffer_by_name = function(_, entry)
      return entry.value
    end,

    define_preview = function(self, entry, status)
      putils.job_maker({ 'git', '-P', 'diff', entry.value .. '^!' }, self.state.bufnr, {
        value = entry.value,
        bufname = self.state.bufname
      })
      putils.regex_highlighter(self.state.bufnr, 'diff')
    end
  }
end, {})

previewers.git_file_diff = defaulter(function(_)
  return previewers.new_buffer_previewer {
    get_buffer_by_name = function(_, entry)
      return entry.value
    end,

    define_preview = function(self, entry, status)
      if entry.status and entry.status == '??' then
        local p = from_entry.path(entry, true)
        if p == nil or p == '' then return end
        conf.buffer_previewer_maker(p, self.state.bufnr, {
          bufname = self.state.bufname
        })
      else
        putils.job_maker({ 'git', '-P', 'diff', entry.value }, self.state.bufnr, {
          value = entry.value,
          bufname = self.state.bufname
        })
        putils.regex_highlighter(self.state.bufnr, 'diff')
      end
    end
  }
end, {})

previewers.autocommands = defaulter(function(_)
  return previewers.new_buffer_previewer {
    teardown = function(self)
      if self.state and self.state.last_set_bufnr and vim.api.nvim_buf_is_valid(self.state.last_set_bufnr) then
        pcall(vim.api.nvim_buf_clear_namespace, self.state.last_set_bufnr, ns_previewer, 0, -1)
      end
    end,

    get_buffer_by_name = function(_, entry)
      return entry.group
    end,

    define_preview = function(self, entry, status)
      local results = vim.tbl_filter(function (x)
        return x.group == entry.group
      end, status.picker.finder.results)

      if self.state.last_set_bufnr then
        pcall(vim.api.nvim_buf_clear_namespace, self.state.last_set_bufnr, ns_previewer, 0, -1)
      end

      local selected_row = 0
      if self.state.bufname ~= entry.group then
        local display = {}
        table.insert(display, string.format(" augroup: %s - [ %d entries ]", entry.group, #results))
        -- TODO: calculate banner width/string in setup()
        -- TODO: get column characters to be the same HL group as border
        table.insert(display, string.rep("─", vim.fn.getwininfo(status.preview_win)[1].width))

        for idx, item in ipairs(results) do
          if item == entry then
            selected_row = idx
          end
          table.insert(display,
            string.format("  %-14s▏%-08s %s", item.event, item.ft_pattern, item.command)
          )
        end

        vim.api.nvim_buf_set_option(self.state.bufnr, "filetype", "vim")
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, display)
        vim.api.nvim_buf_add_highlight(self.state.bufnr, 0, "TelescopeBorder", 1, 0, -1)
      else
        for idx, item in ipairs(results) do
          if item == entry then
            selected_row = idx
            break
          end
        end
      end

      vim.api.nvim_buf_add_highlight(self.state.bufnr, ns_previewer, "TelescopePreviewLine", selected_row + 1, 0, -1)
      vim.api.nvim_win_set_cursor(status.preview_win, {selected_row + 1, 0})

      self.state.last_set_bufnr = self.state.bufnr
    end,
  }
end, {})

previewers.highlights = defaulter(function(_)
  return previewers.new_buffer_previewer {
    teardown = function(self)
      if self.state and self.state.last_set_bufnr and vim.api.nvim_buf_is_valid(self.state.last_set_bufnr) then
        vim.api.nvim_buf_clear_namespace(self.state.last_set_bufnr, ns_previewer, 0, -1)
      end
    end,

    get_buffer_by_name = function()
      return "highlights"
    end,

    define_preview = function(self, entry, status)
      putils.with_preview_window(status, nil, function()
        if not self.state.bufname then
          local output = vim.split(vim.fn.execute('highlight'), '\n')
          local hl_groups = {}
          for _, v in ipairs(output) do
            if v ~= '' then
              if v:sub(1, 1) == ' ' then
                local part_of_old = v:match('%s+(.*)')
                hl_groups[table.getn(hl_groups)] = hl_groups[table.getn(hl_groups)] .. part_of_old
              else
                table.insert(hl_groups, v)
              end
            end
          end

          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, hl_groups)
          for k, v in ipairs(hl_groups) do
            local startPos = string.find(v, 'xxx', 1, true) - 1
            local endPos = startPos + 3
            local hlgroup = string.match(v, '([^ ]*)%s+.*')
            pcall(vim.api.nvim_buf_add_highlight, self.state.bufnr, 0, hlgroup, k - 1, startPos, endPos)
          end
        end

        pcall(vim.api.nvim_buf_clear_namespace, self.state.bufnr, ns_previewer, 0, -1)
        vim.cmd "norm! gg"
        vim.fn.search(entry.value .. ' ')
        local lnum = vim.fn.line('.')
        -- That one is actually a match but its better to use it like that then matchadd
        vim.api.nvim_buf_add_highlight(self.state.bufnr,
          ns_previewer,
          "TelescopePreviewMatch",
          lnum - 1,
          0,
          #entry.value)
      end)
    end,
  }
end, {})

previewers.display_content = defaulter(function(_)
  return previewers.new_buffer_previewer {
    define_preview = function(self, entry, status)
      putils.with_preview_window(status, nil, function()
        assert(type(entry.preview_command) == 'function',
               'entry must provide a preview_command function which will put the content into the buffer')
        entry.preview_command(entry, self.state.bufnr)
      end)
    end
  }
end, {})

return previewers

defmodule Hyperlang.Manpage do
  @moduledoc """
  Render a troff man(2) page for an allowlisted stdlib module.

  The documentation text comes from the real OTP EEP-48 chunk returned by
  `:code.get_doc/1`. The page lists only the `{function, arity}` pairs that
  the Hyperlang stdlib allowlist admits, so it documents exactly what a guest
  may call.

  The output uses a small macro set: `.TH NAME 2`, `.SH`, `.B`, `.I`, `.PP`,
  `.IP`, `.EX`/`.EE` and `.nf`/`.fi`. Doc-text lines that begin with a troff
  control character (`.` or `'`) get a leading `\\&`, and literal backslashes
  are emitted as `\\e`, so prose never parses as a macro.
  """

  @section "2"

  @doc """
  Render the man(2) page for `module` as iodata.

  Returns `{:ok, iodata}` on success, or `{:error, reason}` when the module has
  no OTP documentation chunk (`{:error, {:no_doc_chunk, module, detail}}`) or no
  allowlisted exports (`{:error, {:no_allowed_functions, module}}`).
  """
  @spec render(atom() | binary()) :: {:ok, iodata()} | {:error, term()}
  def render(module) do
    mod_str = to_string(module)
    mod_atom = ensure_atom(module)

    with {:ok, atom} <- mod_atom,
         {:ok, {:docs_v1, _anno, _lang, _format, module_doc, _meta, entries}} <- get_doc(atom) do
      allowed = allowed_entries(mod_str, entries)

      case allowed do
        [] -> {:error, {:no_allowed_functions, mod_str}}
        _ -> {:ok, build_page(mod_str, module_doc, allowed)}
      end
    else
      {:error, _} = error -> error
    end
  end

  ## Doc-chunk discovery ------------------------------------------------------

  defp ensure_atom(module) when is_atom(module), do: {:ok, module}

  defp ensure_atom(module) when is_binary(module) do
    {:ok, String.to_existing_atom(module)}
  rescue
    ArgumentError -> {:error, {:no_doc_chunk, module, :unknown_module}}
  end

  defp get_doc(atom) do
    case :code.get_doc(atom) do
      {:ok, {:docs_v1, _, _, _, _, _, _} = chunk} -> {:ok, chunk}
      {:error, reason} -> {:error, {:no_doc_chunk, atom, reason}}
      other -> {:error, {:no_doc_chunk, atom, other}}
    end
  end

  # The allowlisted `{name, arity}` entries, in `{name, arity}` sort order,
  # carrying the EEP-48 signature and doc content. Non-function entries (types,
  # callbacks) are dropped.
  defp allowed_entries(mod_str, entries) do
    for {{:function, name, arity}, _anno, signatures, doc, _meta} <- entries,
        Hyperlang.StdlibAllowlist.allowed?(mod_str, Atom.to_string(name), arity) do
      {name, arity, signature(name, arity, signatures), doc_text(doc)}
    end
    |> Enum.sort_by(fn {name, arity, _sig, _doc} -> {Atom.to_string(name), arity} end)
  end

  defp signature(name, arity, signatures) do
    case signatures do
      [sig | _] when is_binary(sig) and byte_size(sig) > 0 -> sig
      _ -> default_signature(Atom.to_string(name), arity)
    end
  end

  defp default_signature(name, 0), do: name <> "()"

  defp default_signature(name, arity) do
    args = Enum.map_join(1..arity, ", ", &("Arg" <> Integer.to_string(&1)))
    name <> "(" <> args <> ")"
  end

  defp doc_text(%{} = doc) do
    case Map.get(doc, "en") || Map.get(doc, <<"en">>) do
      text when is_binary(text) -> text
      _ -> nil
    end
  end

  defp doc_text(_), do: nil

  ## Page assembly -----------------------------------------------------------

  defp build_page(mod_str, module_doc, allowed) do
    upper = String.upcase(mod_str)
    module_doc_text = doc_text(module_doc)

    [
      th_line(upper),
      name_section(mod_str, module_doc_text),
      synopsis_section(allowed),
      description_section(mod_str, module_doc_text, allowed),
      source_section(mod_str),
      "\n"
    ]
  end

  defp th_line(upper), do: [".TH ", upper, " ", @section, "\n"]

  # NAME: `<module> \- <one-line summary>` derived from the first sentence/line
  # of the moduledoc.
  defp name_section(mod_str, module_doc_text) do
    summary = one_liner(module_doc_text) || mod_str <> " module"

    [
      ".SH NAME\n",
      mod_str,
      " \\- ",
      escape_inline(summary),
      "\n"
    ]
  end

  # SYNOPSIS: each allowed export's signature, one `.B` line each. Show the
  # module-qualified call so it reads as a usable form.
  defp synopsis_section(allowed) do
    body =
      Enum.map(allowed, fn {_name, _arity, sig, _doc} ->
        [".B ", troff_quote(sig), "\n", ".br\n"]
      end)

    [".SH SYNOPSIS\n", body]
  end

  # DESCRIPTION: the moduledoc prose, then one labeled block per allowed export
  # (its signature in bold, then its `-doc` prose).
  defp description_section(mod_str, module_doc_text, allowed) do
    intro =
      case module_doc_text do
        nil ->
          ["The ", mod_str, " module.\n"]

        text ->
          markdown_to_troff(text)
      end

    fns =
      Enum.map(allowed, fn {name, arity, sig, doc} ->
        header = [
          ".PP\n",
          ".B ",
          troff_quote(sig),
          "\n",
          ".br\n",
          ".RS\n"
        ]

        body =
          case doc do
            nil ->
              [
                "No documentation for ",
                Atom.to_string(name),
                "/",
                Integer.to_string(arity),
                ".\n"
              ]

            text ->
              markdown_to_troff(text)
          end

        [header, body, ".RE\n"]
      end)

    [".SH DESCRIPTION\n", intro, fns]
  end

  defp source_section(mod_str) do
    [
      ".SH SOURCE\n",
      ".B OTP stdlib ",
      escape_inline(mod_str),
      "\n",
      ".br\n",
      "Generated from the OTP EEP-48 documentation chunk; restricted to the\n",
      "Hyperlang-allowlisted exports.\n"
    ]
  end

  ## Text rendering ----------------------------------------------------------

  defp one_liner(nil), do: nil

  defp one_liner(text) do
    text
    |> String.split(~r/\n\s*\n/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> first_sentence()
    |> nilify_empty()
  end

  defp first_sentence(line) do
    case String.split(line, ~r/(?<=[.!?])\s/, parts: 2) do
      [sentence | _] -> String.trim_trailing(sentence, ".")
      [] -> line
    end
  end

  defp nilify_empty(""), do: nil
  defp nilify_empty(s), do: s

  # Convert a markdown doc block into troff body lines. We do a light, readable
  # transform: fenced/indented code -> `.EX`/`.EE` verbatim, blank lines ->
  # `.PP`, and every text line escaped so it never parses as a macro.
  defp markdown_to_troff(text) when is_binary(text) do
    text
    |> normalize_newlines()
    |> String.split("\n")
    |> render_lines(false, [])
    |> Enum.reverse()
  end

  defp normalize_newlines(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  # Walk the lines tracking whether we are inside a fenced code block. `acc` is
  # reversed iodata.
  defp render_lines([], in_code?, acc) do
    if in_code?, do: [".EE\n" | acc], else: acc
  end

  defp render_lines([line | rest], in_code?, acc) do
    cond do
      fence?(line) and in_code? ->
        render_lines(rest, false, [".EE\n" | acc])

      fence?(line) ->
        render_lines(rest, true, [".EX\n" | acc])

      in_code? ->
        render_lines(rest, true, [verbatim_line(line) | acc])

      blank?(line) ->
        render_lines(rest, false, [".PP\n" | acc])

      true ->
        render_lines(rest, false, [text_line(line) | acc])
    end
  end

  defp fence?(line), do: String.starts_with?(String.trim_leading(line), "```")
  defp blank?(line), do: String.trim(line) == ""

  # A prose line: strip markdown emphasis/inline-code markers, drop heading and
  # list bullets to plain text, escape troff specials, guard leading control
  # chars, and end with a real newline.
  defp text_line(line) do
    rendered =
      line
      |> strip_markdown_inline()
      |> escape_inline()
      |> guard_leading_control()

    [rendered, "\n"]
  end

  # A verbatim (code) line inside `.EX`/`.EE`: only escape backslashes and guard
  # the leading control char; preserve internal spacing.
  defp verbatim_line(line) do
    rendered =
      line
      |> escape_backslashes()
      |> guard_leading_control()

    [rendered, "\n"]
  end

  # Strip light markdown: `**bold**`, `_em_`, backtick code spans, link syntax,
  # leading heading hashes and list markers. We keep the text content.
  defp strip_markdown_inline(line) do
    line
    |> String.replace(~r/^[#]{1,6}\s+/, "")
    |> String.replace(~r/^\s*[-*+]\s+/, "  - ")
    |> String.replace(~r/`([^`]*)`/, "\\1")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "\\1")
    |> String.replace(~r/\*([^*]+)\*/, "\\1")
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/\{:[^}]*\}/, "")
    |> String.replace(~r/[ \t]+$/, "")
  end

  # Escape troff inline specials in prose: backslash first (so we don't double
  # escape), then the only other char troff treats specially mid-line in this
  # dialect is the backslash itself; everything else is literal. A leading `'`
  # or `.` is handled separately by `guard_leading_control/1`.
  defp escape_inline(text) do
    escape_backslashes(text)
  end

  defp escape_backslashes(text), do: String.replace(text, "\\", "\\e")

  # If a line begins with a troff control character (`.` or `'`), prefix the
  # zero-width `\&` so `parseline` treats it as text rather than a macro.
  defp guard_leading_control(text) do
    case text do
      "." <> _ -> ["\\&", text]
      "'" <> _ -> ["\\&", text]
      _ -> text
    end
  end

  # Quote a signature for a `.B` macro: parseman splits macro params on
  # whitespace, so wrap multi-token signatures in double quotes to keep them on
  # one bold run.
  defp troff_quote(text) do
    escaped = text |> escape_backslashes() |> IO.iodata_to_binary()

    if String.contains?(escaped, " ") do
      ["\"", String.replace(escaped, "\"", "'"), "\""]
    else
      escaped
    end
  end
end

-- Turns one raw user prompt into the text a human would use to name it, or
-- NULL when the prompt is something the harness emitted rather than something
-- the operator said.
--
-- Claude Code stores several kinds of non-prose in the same `user` slot as a
-- typed prompt: slash-command invocations, `!` shell commands, the stdout of
-- both, and hook output. Naming a session from the raw first prompt is how a
-- session ends up called `<command-name>/clear</command-name>`.
CREATE OR REPLACE FUNCTION public.prompt_title(prompt text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  WITH stripped AS (
    -- A system reminder is appended to whatever the operator typed. It is
    -- never part of what they meant to say, so it never reaches the title.
    SELECT btrim(regexp_replace(COALESCE(prompt, ''),
                                '<system-reminder>.*?</system-reminder>', ' ', 'gs')) AS body
  ), parts AS (
    SELECT
      body,
      -- The three command tags arrive in no fixed order -- `/ui-ux-pro-max`
      -- leads with `<command-message>`, `/clear` with `<command-name>` -- so
      -- each is matched on its own rather than as one anchored pattern.
      btrim(COALESCE((regexp_match(body, '<command-name>\s*/?(.*?)</command-name>', 's'))[1], '')) AS command,
      btrim(COALESCE((regexp_match(body, '<command-args>(.*?)</command-args>', 's'))[1], '')) AS args,
      btrim(COALESCE((regexp_match(body, '<bash-input>(.*?)</bash-input>', 's'))[1], '')) AS shell
    FROM stripped
  )
  SELECT NULLIF(btrim(regexp_replace(
    CASE
      WHEN body = '' THEN ''
      -- Output, not input. Never a name.
      WHEN body ~ '^<(local-command-(stdout|stderr|caveat)|bash-(stdout|stderr)|task-notification|user-prompt-submit-hook|ide_[a-z_]+)>'
        THEN ''
      -- `/skill some request` carries the request in its args; that is the
      -- interesting half, but the command name says which lens it ran under.
      WHEN body ~ '^<command-' AND command <> '' AND args <> ''
        THEN '/' || command || ' — ' || args
      WHEN body ~ '^<command-' AND command <> ''
        THEN '/' || command
      WHEN body ~ '^<bash-input>' AND shell <> ''
        THEN '$ ' || shell
      -- Prose, with newlines collapsed so a multi-line prompt still renders
      -- as a single line.
      ELSE body
    END, '\s+', ' ', 'g')), '')
  FROM parts;
$function$

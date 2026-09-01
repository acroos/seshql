-- How title-worthy a prompt is, lowest first. `Sessions::Ingester` orders a
-- session's prompts by this and then by time, so the opening `/clear`,
-- `/model`, or `!git status` loses to the first thing the operator actually
-- asked for -- however far into the session that was.
--
-- Ranking reads `prompt_title`'s output rather than re-parsing the prompt, so
-- the two cannot drift apart.
CREATE OR REPLACE FUNCTION public.prompt_title_rank(prompt text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  SELECT CASE
    WHEN title IS NULL THEN 99  -- harness output; never a name
    -- A stated request, whether typed plainly or handed to a slash command.
    -- `/ui-ux-pro-max — redesign this leaderboard` says as much as prose does,
    -- so it competes on time rather than losing to every later sentence.
    WHEN title LIKE '/%' AND title LIKE '% — %' THEN 0
    WHEN title NOT LIKE '/%' AND title NOT LIKE '$ %' AND char_length(title) >= 12 THEN 0
    WHEN title NOT LIKE '/%' AND title NOT LIKE '$ %' THEN 1  -- "ok", "yes", "ship it"
    WHEN title LIKE '$ %' THEN 2                              -- a ! shell command
    ELSE 3                                                    -- bare /clear, /model, /login
  END
  FROM (SELECT prompt_title(prompt) AS title) t;
$function$

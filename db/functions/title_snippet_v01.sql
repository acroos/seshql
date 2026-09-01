-- Truncates to `max_length` on a word boundary, with an ellipsis. `LEFT()`
-- alone cuts mid-word, which is how a title ends `</command-`.
CREATE OR REPLACE FUNCTION public.title_snippet(body text, max_length integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  SELECT CASE
    WHEN body IS NULL OR char_length(body) <= max_length THEN body
    ELSE left(
           -- Drop back to the last whole word. A first word that already
           -- fills the budget has no boundary to find, so it is cut instead.
           COALESCE(NULLIF(regexp_replace(left(body, max_length + 1), '\s+\S*$', ''), ''), body),
           max_length
         ) || '…'
  END;
$function$

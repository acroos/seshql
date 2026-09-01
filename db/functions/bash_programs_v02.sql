CREATE OR REPLACE FUNCTION public.bash_programs(cmd text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  SELECT array_agg(prog)
  FROM (
    SELECT (regexp_match(
      segment,
      '^\s*(?:\w+=\S+\s+)*([\w./-]+)'
    ))[1] AS prog
    FROM regexp_split_to_table(cmd, '\s*(?:&&|\|\||;|\|)\s*') AS segment
  ) s
  WHERE prog ~ '[A-Za-z]'
    AND prog NOT IN ('if','then','else','elif','fi','for','while','until','do','done','case','esac','in','end','function','select');
$function$

CREATE OR REPLACE FUNCTION public.shell_command(input jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  SELECT CASE jsonb_typeof(input->'command')
    WHEN 'string' THEN input->>'command'
    WHEN 'array' THEN
      CASE
        WHEN jsonb_array_length(input->'command') = 3
         AND (input->'command'->>0) ~ '(^|/)(ba|z|k|da)?sh$'
         AND (input->'command'->>1) ~ '^-[a-z]*c[a-z]*$'
        THEN input->'command'->>2
        ELSE (
          SELECT string_agg(value, ' ' ORDER BY ordinality)
          FROM jsonb_array_elements_text(input->'command')
            WITH ORDINALITY AS t(value, ordinality)
        )
      END
  END;
$function$

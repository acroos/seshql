# `fx` appends its `create_function` statements after the tables, but
# `content_blocks` has stored generated columns whose expressions call
# `bash_programs()` and `shell_command()`. Postgres resolves those calls when
# the column is created, so a schema dumped in fx's default order cannot be
# loaded into an empty database.
#
# Moving the functions up to just after the extensions makes `db/schema.rb`
# self-contained again, which is what `db:prepare` and `db:test:prepare` need.
module FunctionsBeforeTables
  def extensions(stream)
    super
    functions(stream) if respond_to?(:functions, true)
  end

  # fx still calls this once it has finished with the tables; the second call
  # is dropped so the definitions are not emitted twice.
  def functions(stream)
    return if @functions_dumped

    @functions_dumped = true
    super
  end
end

# Prepended to the PostgreSQL dumper rather than the base class: the subclass
# defines `extensions` itself, so a module in front of the parent would never
# be consulted.
ActiveSupport.on_load(:active_record_postgresqladapter) do
  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(FunctionsBeforeTables)
end

# data_input.jl: reads the items and sheets tables (from CSV text or from the
# rows typed into the page), checks them, and splits them into groups that are
# run separately.
#
# Both tables are lists of rows, each row a Dict from a column name to the text
# in that cell. A CSV file is turned into the same rows, so a file that is
# uploaded and a table that is typed in are checked by the same code.
#
#   items:   item_id, value, width, height, thickness, material, finish,
#            can_rotate, demand_period_1, demand_period_2, ...
#   sheets:  sheet_id, width, height, thickness, material, finish, quantity
#
# A group is one combination of thickness, material and finish. Items and
# sheets only meet within a group, so each group is a separate problem.
#
# This file holds no solver types, so the web server can load it without the
# models.
#
# Requires: APP_DEMAND_COLUMN_PREFIX (solver/src/constants.jl)

# --- Columns ---

const ITEM_COLUMNS  = ["item_id", "value", "width", "height", "thickness", "material", "finish", "can_rotate"]
const SHEET_COLUMNS = ["sheet_id", "width", "height", "thickness", "material", "finish", "quantity"]

# Other spellings of a column name that are accepted when a file is read
const COLUMN_ALIASES = Dict(
    "id" => "item_id", "item" => "item_id", "name" => "item_id", "part_id" => "item_id", "part" => "item_id",
    "price" => "value", "item_value" => "value",
    "length" => "height",
    "rotate" => "can_rotate", "rotation" => "can_rotate", "rotatable" => "can_rotate", "can_be_rotated" => "can_rotate",
    "sheet" => "sheet_id", "stock_id" => "sheet_id",
    "qty" => "quantity", "stock" => "quantity", "count" => "quantity", "number" => "quantity",
    "yearly_demand" => APP_DEMAND_COLUMN_PREFIX * "1", "annual_demand" => APP_DEMAND_COLUMN_PREFIX * "1",
    "demand" => APP_DEMAND_COLUMN_PREFIX * "1",
)

"""
    demand_column(period) -> String

The name of the demand column for `period`, such as `demand_period_3`.
"""
demand_column(period::Int)::String = APP_DEMAND_COLUMN_PREFIX * string(period)

"""
    demand_period(column) -> Union{Int, Nothing}

The period a demand column is for, or `nothing` if `column` is not a demand
column.
"""
function demand_period(column::AbstractString)::Union{Int, Nothing}
    startswith(column, APP_DEMAND_COLUMN_PREFIX) || return nothing
    return tryparse(Int, column[length(APP_DEMAND_COLUMN_PREFIX) + 1:end])
end

# The canonical name of a column heading: lower case, with spaces and hyphens as
# underscores, and an alias replaced by the name it stands for
function canonical_column(heading::AbstractString)::String
    name = lowercase(strip(String(heading)))
    name = replace(name, r"\s*\([^)]*\)" => "")
    name = replace(name, r"[\s\-]+" => "_")
    name = replace(name, r"_(mm|units?)$" => "")
    return get(COLUMN_ALIASES, name, name)
end

# --- Reading CSV text ---

"""
    parse_csv_text(text) -> Vector{Vector{String}}

The rows of CSV `text`, each a list of cell texts. Handles quoted cells (with
commas, line breaks and doubled quotes inside), a leading byte order mark, and
either line ending. A semicolon is the separator when the first line has more
semicolons than commas. Blank lines are dropped.
"""
function parse_csv_text(text::AbstractString)::Vector{Vector{String}}
    text = startswith(text, "﻿") ? text[nextind(text, 1):end] : String(text)
    first_line = first(split(text, '\n'; limit = 2))
    separator  = count(==(';'), first_line) > count(==(','), first_line) ? ';' : ','

    rows   = Vector{Vector{String}}()
    row    = String[]
    cell   = IOBuffer()
    quoted = false
    chars  = collect(text)
    i      = 1
    while i <= length(chars)
        c = chars[i]
        if quoted
            if c == '"'
                if i < length(chars) && chars[i + 1] == '"'
                    write(cell, '"')
                    i += 1
                else
                    quoted = false
                end
            else
                write(cell, c)
            end
        elseif c == '"'
            quoted = true
        elseif c == separator
            push!(row, String(take!(cell)))
        elseif c == '\n' || c == '\r'
            c == '\r' && i < length(chars) && chars[i + 1] == '\n' && (i += 1)
            push!(row, String(take!(cell)))
            any(!isempty(strip(x)) for x in row) && push!(rows, row)
            row = String[]
        else
            write(cell, c)
        end
        i += 1
    end
    push!(row, String(take!(cell)))
    any(!isempty(strip(x)) for x in row) && push!(rows, row)
    return rows
end

"""
    table_from_csv(kind, text) -> NamedTuple

The rows of an items file (`kind = "items"`) or a sheets file (`"sheets"`) as
`(columns, rows, ignored)`: the columns of the table in the order they are shown
(the demand columns are those of the file), one Dict per row from column to cell
text, with an empty cell for a column the file does not have, and the headings
that were not recognised and so are left out. Errors if the text is empty or lacks a
required column.
"""
function table_from_csv(kind::AbstractString, text::AbstractString)
    kind in ("items", "sheets") || error("kind must be \"items\" or \"sheets\", got \"$kind\"")
    cells = parse_csv_text(text)
    isempty(cells) && error("the file is empty")

    headings = [canonical_column(h) for h in cells[1]]
    known    = kind == "items" ? ITEM_COLUMNS : SHEET_COLUMNS
    recognised(h) = h in known || demand_period(h) !== nothing
    required = kind == "items" ? ["item_id", "value", "width", "height"] : ["sheet_id", "width", "height", "quantity"]
    missing_columns = [c for c in required if !(c in headings)]
    isempty(missing_columns) ||
        error("the $kind file has no " * join(("\"$c\"" for c in missing_columns), ", ") * " column")
    kind == "items" && !any(demand_period(h) !== nothing for h in headings) &&
        error("the items file has no demand column; add \"$(demand_column(1))\"")

    ignored = [String(strip(cells[1][k])) for (k, h) in enumerate(headings) if !recognised(h)]
    periods = sort(unique(p for p in (demand_period(h) for h in headings) if p !== nothing))
    columns = kind == "items" ? vcat(ITEM_COLUMNS, [demand_column(p) for p in periods]) : copy(SHEET_COLUMNS)

    rows = Dict{String, String}[]
    for line in cells[2:end]
        row = Dict{String, String}(c => "" for c in columns)
        for (k, h) in enumerate(headings)
            h in columns || continue
            row[h] = k <= length(line) ? String(strip(line[k])) : ""
        end
        push!(rows, row)
    end
    return (columns = columns, rows = rows, ignored = ignored)
end

# --- Checked records ---

struct ItemRecord
    row         :: Int
    item_id     :: String
    value       :: Float64
    width       :: Float64
    height      :: Float64
    thickness   :: String
    material    :: String
    finish      :: String
    can_rotate  :: Bool
    demand      :: Vector{Int}      # one entry per period
end

struct SheetRecord
    row        :: Int
    sheet_id   :: String
    width      :: Float64
    height     :: Float64
    thickness  :: String
    material   :: String
    finish     :: String
    quantity   :: Int
end

# One combination of thickness, material and finish. `items` and `sheets` hold
# positions in the checked item and sheet lists.
struct Group
    thickness :: String
    material  :: String
    finish    :: String
    label     :: String
    items     :: Vector{Int}
    sheets    :: Vector{Int}
end

# A problem found in a table: `table` is "items" or "sheets", `row` the data row
# (1 is the first row under the heading, 0 for the table as a whole)
struct Problem
    table   :: String
    row     :: Int
    column  :: String
    message :: String
end

# --- Reading cells ---

cell_text(row::AbstractDict, column::String)::String =
    haskey(row, column) && row[column] !== nothing ? String(strip(string(row[column]))) : ""

function cell_number(row, column, problems, table, index; positive::Bool = true)::Union{Float64, Nothing}
    text = cell_text(row, column)
    if isempty(text)
        push!(problems, Problem(table, index, column, "$column is empty"))
        return nothing
    end
    number = tryparse(Float64, text)
    if number === nothing || !isfinite(number)
        push!(problems, Problem(table, index, column, "$column must be a number, got \"$text\""))
        return nothing
    end
    if positive && number <= 0
        push!(problems, Problem(table, index, column, "$column must be above 0, got $text"))
        return nothing
    end
    return number
end

# A whole number at least 0 in a cell. An empty cell is `empty_value`, or a
# problem when that is `nothing`.
function cell_count(row, column, problems, table, index; empty_value::Union{Int, Nothing} = nothing)::Union{Int, Nothing}
    text = cell_text(row, column)
    if isempty(text)
        empty_value === nothing && push!(problems, Problem(table, index, column, "$column is empty"))
        return empty_value
    end
    number = tryparse(Float64, text)
    if number === nothing || !isfinite(number) || number < 0 || number != round(number)
        push!(problems, Problem(table, index, column, "$column must be a whole number of 0 or more, got \"$text\""))
        return nothing
    end
    return Int(number)
end

# The thickness of a cell as text that is the same for the same number: blank
# stays blank, "1.50" and "1.5" both become "1.5"
function cell_thickness(row, problems, table, index)::String
    text = cell_text(row, "thickness")
    isempty(text) && return ""
    number = tryparse(Float64, text)
    if number === nothing || !isfinite(number) || number <= 0
        push!(problems, Problem(table, index, "thickness", "thickness must be a number above 0 or empty, got \"$text\""))
        return text
    end
    return replace(string(number), r"\.0$" => "")
end

function cell_rotation(row, problems, index)::Union{Bool, Nothing}
    text = lowercase(cell_text(row, "can_rotate"))
    text in ("yes", "y", "true", "1") && return true
    text in ("no", "n", "false", "0") && return false
    push!(problems, Problem("items", index, "can_rotate",
                            isempty(text) ? "can_rotate is empty; use yes or no" : "can_rotate must be yes or no, got \"$text\""))
    return nothing
end

# --- Checking the tables ---

# Two texts are the same material or finish when they match ignoring case
same_text(a::AbstractString, b::AbstractString) = lowercase(a) == lowercase(b)

"""
    check_tables(item_rows, sheet_rows) -> NamedTuple

Checks the rows of the items table and the sheets table. Returns
`(problems, warnings, items, sheets, n_periods, groups)`:
  - `problems`: what stops a run, as `Problem`s. When there are any, the other
    parts are empty.
  - `warnings`: notes that do not stop a run, as `Problem`s.
  - `items`, `sheets`: the checked `ItemRecord`s and `SheetRecord`s.
  - `n_periods`: the periods of demand. This is the highest period with any
    demand, so a table with only period 1 filled in is one period, a year's
    demand.
  - `groups`: the `Group`s, one for each combination of thickness, material and
    finish, sorted by material, finish and thickness.
"""
function check_tables(item_rows::AbstractVector, sheet_rows::AbstractVector)
    problems = Problem[]
    warnings = Problem[]

    isempty(item_rows)  && push!(problems, Problem("items", 0, "", "the items table has no rows"))
    isempty(sheet_rows) && push!(warnings, Problem("sheets", 0, "", "the sheets table has no rows; only the infinite sheet option can run"))

    # The periods: the highest demand column with anything in it
    demand_columns = sort(unique(demand_period(String(k)) for row in item_rows for k in keys(row)
                                 if demand_period(String(k)) !== nothing))
    filled_periods = [p for p in demand_columns if any(!isempty(cell_text(row, demand_column(p))) for row in item_rows)]
    n_periods      = isempty(filled_periods) ? 1 : maximum(filled_periods)

    items  = ItemRecord[]
    for (index, row) in enumerate(item_rows)
        before = length(problems)
        item_id = cell_text(row, "item_id")
        isempty(item_id) && push!(problems, Problem("items", index, "item_id", "item_id is empty"))
        value  = cell_number(row, "value",  problems, "items", index)
        width  = cell_number(row, "width",  problems, "items", index)
        height = cell_number(row, "height", problems, "items", index)
        thickness = cell_thickness(row, problems, "items", index)
        rotation  = cell_rotation(row, problems, index)
        demand    = Int[]
        for p in 1:n_periods
            count = cell_count(row, demand_column(p), problems, "items", index; empty_value = 0)
            push!(demand, count === nothing ? 0 : count)
        end
        length(problems) == before || continue
        push!(items, ItemRecord(index, item_id, value, width, height, thickness,
                                cell_text(row, "material"), cell_text(row, "finish"), rotation, demand))
    end
    seen = Dict{String, Int}()
    for item in items
        key = lowercase(item.item_id)
        haskey(seen, key) && push!(problems, Problem("items", item.row, "item_id",
                                                     "item_id \"$(item.item_id)\" is already used in row $(seen[key])"))
        seen[key] = get(seen, key, item.row)
    end

    sheets = SheetRecord[]
    for (index, row) in enumerate(sheet_rows)
        before = length(problems)
        sheet_id = cell_text(row, "sheet_id")
        isempty(sheet_id) && push!(problems, Problem("sheets", index, "sheet_id", "sheet_id is empty"))
        width    = cell_number(row, "width",  problems, "sheets", index)
        height   = cell_number(row, "height", problems, "sheets", index)
        quantity = cell_count(row, "quantity", problems, "sheets", index)
        thickness = cell_thickness(row, problems, "sheets", index)
        length(problems) == before || continue
        push!(sheets, SheetRecord(index, sheet_id, width, height, thickness,
                                  cell_text(row, "material"), cell_text(row, "finish"), quantity))
    end
    seen = Dict{String, Int}()
    for sheet in sheets
        key = lowercase(sheet.sheet_id)
        haskey(seen, key) && push!(problems, Problem("sheets", sheet.row, "sheet_id",
                                                     "sheet_id \"$(sheet.sheet_id)\" is already used in row $(seen[key])"))
        seen[key] = get(seen, key, sheet.row)
    end

    isempty(problems) || return (problems = problems, warnings = warnings, items = ItemRecord[], sheets = SheetRecord[],
                                 n_periods = n_periods, groups = Group[])

    all(item -> sum(item.demand) == 0, items) &&
        push!(warnings, Problem("items", 0, "", "no item has any demand"))
    groups = build_groups(items, sheets, warnings)
    return (problems = problems, warnings = warnings, items = items, sheets = sheets, n_periods = n_periods, groups = groups)
end

# The groups of the checked records, with a warning for each group that has items
# but no sheets, or sheets but no items. The first spelling met of a material or
# finish is the one shown.
function build_groups(items::Vector{ItemRecord}, sheets::Vector{SheetRecord}, warnings::Vector{Problem})::Vector{Group}
    keys_seen = Tuple{String, String, String}[]            # lower-case material, lower-case finish, thickness
    shown     = Dict{Tuple{String, String, String}, Tuple{String, String, String}}()
    group_key(material, finish, thickness) = (lowercase(material), lowercase(finish), thickness)
    for record in Iterators.flatten((items, sheets))
        key = group_key(record.material, record.finish, record.thickness)
        if !haskey(shown, key)
            shown[key] = (record.material, record.finish, record.thickness)
            push!(keys_seen, key)
        end
    end
    thickness_order(key) = isempty(key[3]) ? -1.0 : parse(Float64, key[3])
    sort!(keys_seen; by = key -> (key[1], key[2], thickness_order(key)))

    groups = Group[]
    for key in keys_seen
        material, finish, thickness = shown[key]
        parts = String[]
        isempty(material)  || push!(parts, material)
        isempty(finish)    || push!(parts, finish)
        isempty(thickness) || push!(parts, thickness * " mm")
        label = isempty(parts) ? "All items and sheets" : join(parts, " / ")
        item_positions  = [k for (k, r) in enumerate(items)  if group_key(r.material, r.finish, r.thickness) == key]
        sheet_positions = [k for (k, r) in enumerate(sheets) if group_key(r.material, r.finish, r.thickness) == key]
        isempty(item_positions) && !isempty(sheet_positions) &&
            push!(warnings, Problem("sheets", 0, "", "no items match the sheets of \"$label\"; they are not used"))
        isempty(sheet_positions) && !isempty(item_positions) &&
            push!(warnings, Problem("items", 0, "", "no sheets match the items of \"$label\"; sheet stock cannot be cut for them"))
        push!(groups, Group(thickness, material, finish, label, item_positions, sheet_positions))
    end
    return groups
end

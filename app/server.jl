# server.jl: the local web server. It serves the page in web/ and a small JSON
# interface that the page uses to check data, start a run, follow it, and read
# its results. It does not load the solver: each run is a separate process
# (job_runner.jl), so a run that fails or is stopped cannot take the server down.
#
# Start it from the application folder:
#   julia --project app/server.jl --open
# which opens the page in the default browser (leave out --open to open the
# address it prints yourself).
#
# The interface:
#   GET  /api/defaults             the default settings and the table columns
#   POST /api/parse_csv            {kind, text} -> {columns, rows, ignored}
#   POST /api/validate             {items, sheets} -> problems, warnings, groups
#   POST /api/jobs                 {name, items, sheets, settings} -> {id}
#   GET  /api/jobs                 every run, newest first
#   GET  /api/jobs/<id>            the run's status and the end of its log
#   GET  /api/jobs/<id>/result     the run's results (result.json)
#   GET  /api/jobs/<id>/input      the data and settings the run was given
#   POST /api/jobs/<id>/cancel     stops a running run
#
# Requires: data_input.jl, settings.jl, solver/src/constants.jl

using HTTP, JSON, Dates, Random

include(joinpath(@__DIR__, "..", "solver", "src", "constants.jl"))
include(joinpath(@__DIR__, "data_input.jl"))
include(joinpath(@__DIR__, "settings.jl"))

const APP_ROOT = normpath(joinpath(@__DIR__, ".."))
const WEB_DIR  = joinpath(APP_ROOT, "web")
const JOBS_DIR = normpath(APP_JOBS_DIR)
const RUNNER   = joinpath(@__DIR__, "job_runner.jl")

# The run processes this server started, by run id
const PROCESSES = Dict{String, Base.Process}()

# How much of the end of a log the page is sent
const LOG_TAIL_CHARACTERS = 40_000

# --- Responses ---

json_response(content; status::Int = 200) =
    HTTP.Response(status, ["Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store"],
                  JSON.json(content))

error_response(message::AbstractString; status::Int = 400) = json_response(Dict("error" => String(message)); status = status)

const CONTENT_TYPES = Dict(
    ".html" => "text/html; charset=utf-8", ".js" => "text/javascript; charset=utf-8",
    ".css" => "text/css; charset=utf-8", ".csv" => "text/csv; charset=utf-8",
    ".json" => "application/json; charset=utf-8", ".svg" => "image/svg+xml", ".png" => "image/png",
    ".ico" => "image/x-icon",
)

# A file of the web folder. Anything that resolves outside the folder is refused.
# joinpath(WEB_DIR, "") is the folder with a trailing separator, whichever
# separator the system uses.
function static_response(relative::AbstractString)
    path = normpath(joinpath(WEB_DIR, relative))
    (startswith(path, joinpath(WEB_DIR, "")) && isfile(path)) || return error_response("not found"; status = 404)
    content_type = get(CONTENT_TYPES, lowercase(splitext(path)[2]), "application/octet-stream")
    return HTTP.Response(200, ["Content-Type" => content_type, "Cache-Control" => "no-store"], read(path))
end

# --- Runs ---

job_dir(id::AbstractString) = joinpath(JOBS_DIR, id)

# A run id is letters, digits and hyphens only, so it can never leave the jobs folder
valid_id(id::AbstractString) = occursin(r"^[0-9A-Za-z\-]{1,60}$", id) && isdir(job_dir(id))

function read_json_file(path::String)
    isfile(path) || return nothing
    try
        return JSON.parsefile(path)
    catch
        return nothing    # being rewritten at this moment; the next poll will read it
    end
end

# Writes a file so that a reader never sees it half written. Replacing a file that
# is being read can fail on some systems, so the replacement is tried again.
function write_json_file(path::String, content)
    temporary = path * ".tmp"
    open(io -> write(io, JSON.json(content)), temporary, "w")
    for attempt in 1:20
        try
            mv(temporary, path; force = true)
            return nothing
        catch
            attempt == 20 && rethrow()
            sleep(0.05)
        end
    end
end

# The state of a run as the page should show it. A run that says it is running but
# has no live process was stopped without finishing (the server restarted, or the
# process died).
function effective_state(id::String, status)
    status === nothing && return "starting"
    state = String(get(status, "state", "running"))
    state == "running" || return state
    process = get(PROCESSES, id, nothing)
    process !== nothing && process_running(process) && return "running"
    return "interrupted"
end

running_job() = (for (id, process) in PROCESSES; process_running(process) && return id; end; nothing)

function start_job(body::AbstractDict)
    running = running_job()
    running === nothing || return error_response("A run is already in progress ($running). Wait for it to finish or cancel it."; status = 409)

    items  = get(body, "items", [])
    sheets = get(body, "sheets", [])
    settings = get(body, "settings", nothing)
    settings isa AbstractDict || (settings = Dict{String, Any}())
    checked = check_tables(items, sheets)
    isempty(checked.problems) || return error_response("The data has errors: " * checked.problems[1].message)
    parsed = read_settings(settings)
    wanted = [g for g in checked.groups if (parsed.groups === nothing || g.label in parsed.groups) && !isempty(g.items)]
    isempty(wanted) && return error_response("No group is chosen to run.")
    if parsed.infinite
        missing_width = [g.label for g in wanted if get(parsed.roll_widths, g.label, 0.0) <= 0]
        isempty(missing_width) || return error_response("Give a roll width for: " * join(missing_width, ", "))
    end

    id = Dates.format(now(), "yyyymmdd-HHMMSS") * "-" * randstring("abcdefghijklmnopqrstuvwxyz0123456789", 4)
    dir = job_dir(id)
    mkpath(dir)
    name = String(strip(string(get(body, "name", ""))))
    write_json_file(joinpath(dir, "input.json"), Dict("items" => items, "sheets" => sheets, "settings" => settings))
    write_json_file(joinpath(dir, "meta.json"), Dict("id" => id, "name" => isempty(name) ? id : name, "created" => time()))
    write_json_file(joinpath(dir, "status.json"),
                    Dict("state" => "running", "stage" => "Starting the solver", "group" => 0, "groups" => length(wanted), "started" => time()))

    command = `$(Base.julia_cmd()) --project=$APP_ROOT $RUNNER $dir`
    process = open(command, "r")
    PROCESSES[id] = process
    @async copy_output_to_log(process, joinpath(dir, "log.txt"))
    return json_response(Dict("id" => id))
end

# Appends what a run prints to its log file as it is printed. The runner sends its
# error messages down the same pipe, so the log is the whole story of the run.
function copy_output_to_log(process::Base.Process, path::String)
    open(path, "w") do log
        while !eof(process)
            write(log, readavailable(process))
            flush(log)
        end
    end
end

function list_jobs()
    entries = Dict{String, Any}[]
    isdir(JOBS_DIR) || return json_response(entries)
    for id in readdir(JOBS_DIR)
        meta = read_json_file(joinpath(JOBS_DIR, id, "meta.json"))
        meta === nothing && continue
        status = read_json_file(joinpath(JOBS_DIR, id, "status.json"))
        push!(entries, Dict{String, Any}(
            "id" => id, "name" => get(meta, "name", id), "created" => get(meta, "created", 0.0),
            "state" => effective_state(id, status),
            "stage" => status === nothing ? "" : get(status, "stage", "")))
    end
    sort!(entries; by = e -> -e["created"])
    return json_response(entries)
end

function job_status(id::String)
    status = read_json_file(joinpath(job_dir(id), "status.json"))
    meta   = read_json_file(joinpath(job_dir(id), "meta.json"))
    log_path = joinpath(job_dir(id), "log.txt")
    log = isfile(log_path) ? read(log_path, String) : ""
    length(log) > LOG_TAIL_CHARACTERS && (log = log[prevind(log, length(log) - LOG_TAIL_CHARACTERS):end])
    return json_response(Dict("id" => id, "name" => meta === nothing ? id : get(meta, "name", id),
                              "status" => status, "state" => effective_state(id, status), "log" => log))
end

function cancel_job(id::String)
    process = get(PROCESSES, id, nothing)
    (process !== nothing && process_running(process)) || return error_response("That run is not running."; status = 409)
    kill(process)
    status = read_json_file(joinpath(job_dir(id), "status.json"))
    status === nothing && (status = Dict{String, Any}())
    status["state"] = "cancelled"
    status["stage"] = "Cancelled"
    status["finished"] = time()
    write_json_file(joinpath(job_dir(id), "status.json"), status)
    return json_response(Dict("id" => id, "state" => "cancelled"))
end

# --- The data interface ---

function group_summary(checked)
    return [Dict{String, Any}(
        "label" => g.label, "thickness" => g.thickness, "material" => g.material, "finish" => g.finish,
        "items" => length(g.items), "sheet_types" => length(g.sheets),
        "sheets" => sum((checked.sheets[k].quantity for k in g.sheets); init = 0),
        "widest_sheet" => maximum((checked.sheets[k].width for k in g.sheets); init = 0.0),
    ) for g in checked.groups]
end

function validate(body::AbstractDict)
    checked = check_tables(get(body, "items", []), get(body, "sheets", []))
    problem(p) = Dict("table" => p.table, "row" => p.row, "column" => p.column, "message" => p.message)
    return json_response(Dict(
        "problems" => [problem(p) for p in checked.problems], "warnings" => [problem(p) for p in checked.warnings],
        "periods" => checked.n_periods, "groups" => group_summary(checked)))
end

# --- Routing ---

function route(request::HTTP.Request)
    uri    = HTTP.URI(request.target)
    path   = String(uri.path)
    method = String(request.method)

    if method == "GET"
        path == "/" && return static_response("index.html")
        startswith(path, "/web/") && return static_response(path[6:end])
        path == "/api/defaults" && return json_response(Dict(
            "settings" => default_settings(), "item_columns" => ITEM_COLUMNS, "sheet_columns" => SHEET_COLUMNS,
            "demand_prefix" => APP_DEMAND_COLUMN_PREFIX))
        path == "/api/jobs" && return list_jobs()
        if (m = match(r"^/api/jobs/([^/]+)(/result|/input)?$", path)) !== nothing
            id = String(m.captures[1])
            valid_id(id) || return error_response("no such run"; status = 404)
            m.captures[2] === nothing && return job_status(id)
            file = m.captures[2] == "/result" ? "result.json" : "input.json"
            content = isfile(joinpath(job_dir(id), file)) ? read(joinpath(job_dir(id), file)) : nothing
            content === nothing && return error_response("not available yet"; status = 404)
            return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store"], content)
        end
    elseif method == "POST"
        body = length(request.body) == 0 ? Dict{String, Any}() : JSON.parse(String(request.body))
        path == "/api/parse_csv" && return json_response(table_from_csv(String(body["kind"]), String(body["text"])))
        path == "/api/validate" && return validate(body)
        path == "/api/jobs" && return start_job(body)
        if (m = match(r"^/api/jobs/([^/]+)/cancel$", path)) !== nothing
            id = String(m.captures[1])
            valid_id(id) || return error_response("no such run"; status = 404)
            return cancel_job(id)
        end
    end
    return error_response("not found"; status = 404)
end

# A mistake in what was sent is reported to the page as a message; anything else is
# a fault of the server, reported with its message and kept in the terminal
function handler(request::HTTP.Request)
    try
        length(request.body) > APP_MAX_REQUEST_BYTES && return error_response("That upload is too large."; status = 413)
        return route(request)
    catch err
        err isa ErrorException && return error_response(err.msg)
        err isa KeyError && return error_response("the request is missing \"$(err.key)\"")
        err isa ArgumentError && occursin("JSON", err.msg) && return error_response("the request is not valid JSON")
        println(stderr, "request failed: ", sprint(showerror, err, catch_backtrace()))
        return error_response("the server could not handle that request: " * sprint(showerror, err); status = 500)
    end
end

# Opens the page in the default browser
function open_browser(url::String)
    command = Sys.isapple() ? `open $url` : Sys.iswindows() ? `cmd /c start $url` : `xdg-open $url`
    try
        run(command; wait = false)
    catch
        println("Open $url in a browser.")
    end
end

function main(args::Vector{String})
    mkpath(JOBS_DIR)
    server = try
        HTTP.serve!(handler, APP_HOST, APP_PORT)
    catch err
        println(stderr, "Could not start the server on port $APP_PORT: ", sprint(showerror, err))
        println(stderr, "Another copy may already be running. Close it, or change APP_PORT in solver/src/constants.jl.")
        exit(1)
    end
    url = "http://$APP_HOST:$APP_PORT"
    println("2D Stock Cutting is running at $url")
    println("Press Ctrl+C to stop it.")
    "--open" in args && open_browser(url)
    try
        wait(server)
    catch err
        err isa InterruptException || rethrow()
    finally
        for (_, process) in PROCESSES
            process_running(process) && kill(process)
        end
        close(server)
    end
end

isfile(PROGRAM_FILE) && samefile(PROGRAM_FILE, @__FILE__) && main(ARGS)

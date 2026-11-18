# Constants shared by every method and by the application, so each value has
# one definition.

# --- Wastage / scrap material valuation ---
#
# Used to value the leftover sheet area of a plan after its patterns have
# been selected, see helper/wastage.jl. Pattern generation and selection
# don't use them. Sheet thickness is in the same unit as item and sheet
# dimensions.
#
# Scrap is valued at 0.0 per kg by default, so waste is reported as an area
# and a share of the cut sheets, and carries no value unless a price is set.
const DEFAULT_STAINLESS_VALUE_PER_KG      = 0.0
const DEFAULT_STAINLESS_DENSITY_KG_PER_M3 = 8000.0
const DEFAULT_SHEET_THICKNESS             = 0.5

# --- Clearance ---
#
# Default gap between neighbouring cut parts, in the same unit as item and
# sheet dimensions (5.0 means 5mm). It is also the minimum gap at a sheet
# edge whose own clearance is 0, whenever a part isn't flush against it.
# Scripts should set their `CLEARANCE` from this, so pattern generation,
# pattern selection and the layout export all use one value.
#
# There are no per-edge defaults here. Each generator defaults its
# `clearance_left/right/top/bottom` keywords to 0.0 (flush allowed), and any
# value above 0 is a mandatory margin for that edge.
const DEFAULT_CLEARANCE = 5.0

# --- Whole-number grid ---
#
# The revised DP and the full pack scale every item and sheet dimension and
# every clearance value by a power of 10 so they are whole numbers, see
# helper/grid_scale.jl. A value is taken to have at most this many decimal
# places: anything finer is floating-point noise, not data, so a value like
# 0.30000000000000004 reads as 0.3 and doesn't make the grid 10^15 times
# finer.
const GRID_MAX_DECIMAL_PLACES = 6

# --- Guillotine DP tie-breaking ---
#
# Two DP values closer than this count as equal, so the option found first
# is kept. Many layouts have exactly the same value, and adding the same
# values in a different order can differ in the last digit, so without this
# the layout would be picked by rounding noise. The DPs try parts, stacks
# and shelves biggest first, so the option kept is the one built from the
# biggest pieces.
const DP_TIE_TOLERANCE = 1e-9

# --- Lexmax weight softening ---
#
# The share of the weight that a lexmax (big-M) anchor pattern gives to the
# items other than its focus item. The focus item gets 1 minus this, and
# every other item an equal share of it, so ties among the other items are
# still broken by value. Every method that builds lexmax anchors defaults to
# this value, so they all use the same one.
const DEFAULT_LEXMAX_EPSILON = 0.05

# --- Dichotomic weights ---
#
# The weights that bisect between two patterns (dichotomic_lambda_pair) are
# floored at MIN_DICHOTOMIC_WEIGHT, so no item is ignored entirely and ties
# among the others are still broken. Two patterns whose weighted difference is
# within DICHOTOMIC_TIE_TOLERANCE tie on the pair of items, so there is nothing
# to bisect between them.
const MIN_DICHOTOMIC_WEIGHT    = 1e-6
const DICHOTOMIC_TIE_TOLERANCE = 1e-10

# --- Holding cost ---
#
# Cost of keeping an item in stock for a year, as a share of its own
# value. It covers the money tied up in the stock, storage space, and the risk of
# damage or of the part no longer being needed. Stock is commonly costed at
# 15-25% a year; this takes the low end because cut metal parts don't spoil and
# date slowly. It is a rule of thumb, not a measured figure.
#
# solve_ip_multi_period charges the items in inventory at the end of every period
# this rate divided by the number of periods in a year. Inventory left at the end
# of the horizon is charged the same, one extra period. Sheets have no holding
# cost: leaving a sheet uncut costs nothing, and cutting one costs the value of
# its best packing.
const DEFAULT_ANNUAL_HOLDING_RATE = 0.15

# --- Months in a year ---
#
# Item demand in the data is annual. solve_ip_min_month measures how long the
# sheets last in months, so it divides annual demand by this many.
const MONTHS_PER_YEAR = 12

# --- Integer programme solver settings ---
#
# Every selection IP is solved until the gap between its plan and the solver's
# bound is within MIP_REL_GAP of the cost or within MIP_ABS_GAP. A relative gap
# of 1e-5 is a hundred-thousandth of the cost, far below the differences between
# plans that matter. A tighter gap can take the solver hours on an instance that
# leaves many sheets uncut, where many plans cost almost the same, and with no
# relative gap it can spend hours proving that a plan it found at once is the
# best. See new_selection_model in helper/ip_model.jl.
const MIP_REL_GAP = 1e-5
const MIP_ABS_GAP = 1e-6

# --- Fully covered ---
#
# solve_ip_min_month counts an item as fully covered at a horizon when the
# units it delivers are within this of the horizon's demand for it.
const COVERAGE_TOLERANCE = 1e-6

# --- Column generation ---
#
# Used by solve_col_gen_multi_period (see helper/col_gen.jl).
#
# COLUMN_GENERATION_MAX_ITERATIONS is the most LP solves in one run.
# COLUMN_GENERATION_GAP_TOLERANCE is the share of the LP value that its lower
# bound may be below it before the run stops early. At 0 the run goes on until
# no pattern can improve the LP. REDUCED_COST_TOLERANCE is how far below 0 a
# pattern's reduced cost must be to count as improving (at least this, scaled
# up by the largest item price when that is above 1). INTEGRALITY_TOLERANCE
# is how far a pattern count may be from a whole number and still count as one.
const COLUMN_GENERATION_MAX_ITERATIONS = 100
const COLUMN_GENERATION_GAP_TOLERANCE  = 0.0
const REDUCED_COST_TOLERANCE           = 1e-6
const INTEGRALITY_TOLERANCE            = 1e-6

# --- Infinite sheet ---
#
# The roll model (see src/Pattern_Selection/infinite_sheet_col_gen.jl) gives a
# representative length of material for a year's demand, and its shelves are not
# cut. Its integer programme is therefore solved to its own gap,
# INFINITE_SHEET_IP_REL_GAP, which is kept apart from MIP_REL_GAP so that the
# two can differ. For a year's demand a gap under the height of one shelf takes
# close to a proof of optimality, which can take branch and bound a very long
# time.
const INFINITE_SHEET_IP_REL_GAP = 1e-5

# --- Application: server ---
#
# The local web server (app/server.jl) listens on APP_HOST and APP_PORT, so the
# page is at http://APP_HOST:APP_PORT. APP_HOST is the loopback address, so the
# page can only be reached from the machine running it. Each run is kept in its
# own folder under APP_JOBS_DIR. APP_MAX_REQUEST_BYTES is the largest upload the
# server accepts.
const APP_HOST              = "127.0.0.1"
const APP_PORT              = 8765
const APP_JOBS_DIR          = joinpath(@__DIR__, "..", "..", "jobs")
const APP_MAX_REQUEST_BYTES = 50_000_000

# --- Application: defaults offered in the settings ---
#
# APP_DEFAULT_IP_TIME_LIMIT is the seconds the integer programme may take on
# one group of items and sheets. A group that runs out of time keeps the best
# plan found so far. APP_DEFAULT_PERIODS_PER_YEAR is the number of periods in a
# year offered when demand is given for several periods, so 12 for months.
# APP_DEFAULT_ROLL_SHELF_HEIGHT is the tallest shelf offered for a roll, in
# the units of the item sizes.
const APP_DEFAULT_IP_TIME_LIMIT       = 300.0
const APP_DEFAULT_PERIODS_PER_YEAR    = 12
const APP_DEFAULT_ROLL_SHELF_HEIGHT   = 3000.0

# --- Application: demand columns ---
#
# A demand column of the items file is named APP_DEMAND_COLUMN_PREFIX followed
# by its period number. When only period 1 has any demand, it is a year's
# demand for one period.
const APP_DEMAND_COLUMN_PREFIX = "demand_period_"

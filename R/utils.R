#' @importFrom R6 R6Class
NULL

#' Install and load an R package if not already installed
#'
#' @param library_name The name of the library to install.
#' @export
library_install <- function(library_name) {
  if (!requireNamespace(library_name, quietly = TRUE)) {
    message(paste("Installing", library_name, "package..."))
    utils::install.packages(library_name)
  }
}


#' Convert an RDS file to a JSON file
#'
#' @param rds_file The path to the input RDS file.
#' @param json_file The path where the output JSON file will be written.
#' @return None. Writes a JSON file to disk.
#' @export
convert_rds_to_json <- function(rds_file, json_file) {
  data <- readRDS(rds_file)
  jsonlite::write_json(data, path = json_file, pretty = TRUE, auto_unbox = TRUE)
  logger::log_info("Converted {rds_file} to {json_file}")
}

#' Convert a cached RDS file to JSON format
#'
#' @param interpro_filename The base filename (without extension) for the RDS file in the cache and the JSON file in the temp directory.
#' @return None. Calls convert_rds_to_json with constructed file paths.
#' @export
convert_myrds_to_json <- function(interpro_filename) {
  convert_rds_to_json(
    rds_file = paste0("cache/", interpro_filename, ".rds"),
    json_file = paste0("temp/", interpro_filename, ".json")
  )
}

#' Log an error message with status information
#'
#' @param finished_count The number of completed tasks.
#' @param total_count The total number of tasks.
#' @param message A glue-formatted message to log.
#' @export
log_error_with_status <- function(finished_count, total_count, message) {
  # Calculate percent complete
  pct_done <- 0
  if (is.na(total_count)) total_count <- 0
  if (total_count > 0) { # avoid division by zero
    pct_done <- round((finished_count / total_count) * 100, 1)
  }
  status <- sprintf("[%2d of %2d: %5.1f%%]", finished_count, total_count, pct_done) # nolint: object_usage_linter.
  formatted_message <- glue::glue(message, .envir = parent.frame()) # nolint: object_usage_linter.
  logger::log_error("{status} {formatted_message}")
}

#' Log an informational message with status information
#'
#' @param finished_count The number of completed tasks.
#' @param total_count The total number of tasks.
#' @param message A glue-formatted message to log.
#' @export
log_info_with_status <- function(finished_count, total_count, message) {
  # Calculate percent complete
  pct_done <- 0
  if (is.na(total_count)) total_count <- 0
  if (total_count > 0) { # avoid division by zero
    pct_done <- floor((finished_count / total_count) * 1000) / 10
  }
  status <- sprintf("[%2d of %2d: %5.1f%%]", finished_count, total_count, pct_done) # nolint: object_usage_linter.
  formatted_message <- glue::glue(message, .envir = parent.frame()) # nolint: object_usage_linter.
  logger::log_info("{status} {formatted_message}")
}

#' Run tasks in parallel and collect results
#'
#' @param task_description A description of the task.
#' @param inputs A list of inputs for the parallel tasks.
#' @param func_to_run The function to execute for each input.
#' @param poll_interval Interval in seconds between polling for task completion.
#' @param ... Additional arguments passed to the function.
#'
#' @return A list of results keyed by the input items.
#' @export
run_parallel_tasks <- function(task_description, inputs, func_to_run, poll_interval = 1, ...) {
  task_description <- glue::glue(task_description, .envir = parent.frame())
  logger::log_info("Starting {task_description}")
  total_count <- length(inputs)

  tasks <- stats::setNames(lapply(seq_along(inputs), function(i) {
    parallel::mcparallel({
      input_name <- inputs[[i]]
      logger::log_info("Starting task for input '{input_name}'")
      func_to_run(input_name, ...)
      # we can't log "finished" here in case one of the threaded functions wants to redirect logging output for this thread/process
    })
  }), inputs)

  results <- list()
  # Poll until all tasks are complete.
  while (length(tasks) > 0) {
    finished <- parallel::mccollect(tasks, wait = FALSE)
    if (length(finished) > 0) {
      for (input_name in names(tasks)) {
        pid <- as.character(tasks[[input_name]]$pid)
        if (pid %in% names(finished)) {
          tasks[[input_name]] <- NULL # Remove finished task.
          res <- finished[[pid]] # get results from thread
          results[[input_name]] <- res # put results from func_to_run in list of all results we send to caller (key=input_name, value=results from func_to_run)

          finished_count <- length(results)
          remaining <- total_count - finished_count # nolint: object_usage_linter.
          pct_done <- round((finished_count / total_count) * 100, 1) # nolint: object_usage_linter.

          if (isTRUE(res$succeeded)) {
            log_info_with_status(finished_count, total_count, "Task for input '{input_name}' finished successfully")
          } else {
            log_info_with_status(finished_count, total_count, "Task for input '{input_name}' finished with failure: {res$output}")
          }
        }
      }
    }
    Sys.sleep(poll_interval)
  }

  successes <- 0
  if (length(results) > 0) {
    successes <- sum(sapply(results, function(res) !is.null(res) && isTRUE(res$succeeded)))
  }
  failures <- total_count - successes # nolint: object_usage_linter.
  logger::log_info("Finished {task_description}. {successes} of {total_count} tasks succeeded, {failures} failed.")
  results
}

#' WebDetailsCache class
#'
#' A class for caching web details including keys, metadata, and entry details.
#'
#' @field cache_name Unique name for the cache.
#' @field cache_dir Directory for cache files.
#' @field log_dir Directory for log files.
#' @field all_entry_keys List of cached entry keys.
#' @field all_entry_details List of cached entry details.
#' @field metadata Metadata associated with the cache.
#' @field list_all_entries_url URL for listing all entries.
#' @field key_field_extraction_func Function to extract the key from entries.
#' @field single_entry_details_url URL template for fetching single entry details.
#' @field all_entry_keys_file File path for storing entry keys.
#' @field metadata_file File path for storing metadata.
#' @field all_entry_details_file File path for storing entry details.
#' @field flush_threshold Number of entry detils fetched before flushing to disk. (improves perf since writing to disk can take a long time)
#' @field list_all_entries_page_size Page size for listing entries.
#' @export
WebDetailsCache <- R6::R6Class("WebDetailsCache", # nolint: object_name_linter, cyclocomp_linter.
  public = list(
    cache_name = "",
    cache_dir = "",
    log_dir = "",
    all_entry_keys = NULL,
    all_entry_details = NULL,
    metadata = NULL,
    list_all_entries_url = "",
    key_field_extraction_func = NULL,
    single_entry_details_url = "",
    all_entry_keys_file = "",
    metadata_file = "",
    all_entry_details_file = "",
    flush_threshold = 0,
    list_all_entries_page_size = 0,

    #' @description initialize a new WebDetailsCache
    #'
    #' @param cache_name Unique name for the cache.
    #' @param cache_dir Directory to store cache files.
    #' @param log_dir Directory for log files.
    #' @param list_all_entries_url URL for listing all entries.
    #' @param key_field_extraction_func Function to extract the key from entries.
    #' @param single_entry_details_url URL template for fetching details for a single entry.
    #' @param flush_threshold flush_threshold Number of entry detils fetched before flushing to disk (default 100).
    #' @param list_all_entries_page_size Number of entries per page (default 1000).
    initialize = function(cache_name, cache_dir, log_dir, list_all_entries_url, key_field_extraction_func, single_entry_details_url, flush_threshold = 100, list_all_entries_page_size = 1000) {
      self$cache_name <- cache_name
      self$cache_dir <- cache_dir
      self$log_dir <- log_dir
      self$all_entry_keys <- list()
      self$all_entry_details <- list()
      self$metadata <- list(next_url_all_entry_keys = NA)
      self$list_all_entries_url <- list_all_entries_url
      self$key_field_extraction_func <- key_field_extraction_func
      self$single_entry_details_url <- single_entry_details_url
      self$all_entry_keys_file <- file.path(self$cache_dir, paste0(cache_name, "_all_entry_keys.rds"))
      self$metadata_file <- file.path(self$cache_dir, paste0(cache_name, "_metadata.rds"))
      self$all_entry_details_file <- file.path(self$cache_dir, paste0(cache_name, "_all_entry_details.rds"))
      self$flush_threshold <- flush_threshold
      self$list_all_entries_page_size <- list_all_entries_page_size
    },

    #' @description Load the cache data from disk
    #'
    #' Loads cached keys, metadata, and entry details from their respective files if they exist.
    load_cache = function() {
      logger::log_info("Loading web details for {self$cache_name} cache from directory: {self$cache_dir}")

      if (file.exists(self$all_entry_keys_file) && file.exists(self$metadata_file)) {
        self$all_entry_keys <- readRDS(self$all_entry_keys_file)
        self$metadata <- readRDS(self$metadata_file)

        if (file.exists(self$all_entry_details_file)) {
          self$all_entry_details <- readRDS(self$all_entry_details_file)
        }
        logger::log_info("Loaded cached data for '{self$cache_name}'")
      } else {
        logger::log_info("Cache files for '{self$cache_name}' do not exist. Skipping load.")
      }
    },

    #' @description Build the cache.
    #'
    #' Loads existing cache data and fetches missing entry keys and details.
    build_cache = function() {
      logger::log_info("Building web details cache for '{self$cache_name}'...")
      self$load_cache()

      if (!self$are_all_entry_keys_cached()) {
        self$fetch_all_entry_keys()
      }

      if (!self$are_all_entry_details_cached()) {
        self$fetch_all_entry_details()
      }

      logger::log_info("Finished building web details cache for '{self$cache_name}'...")
    },

    #' @description Check if all entry keys are cached.
    #'
    #' @return TRUE if the number of cached keys equals the total number of entries; FALSE otherwise.
    are_all_entry_keys_cached = function() {
      list_page_object <- fetch_web_content_as_object(self$list_all_entries_url, query = list(page_size = 1))
      total_num_entries <- list_page_object$count
      total_num_entries == length(self$all_entry_keys)
    },

    #' @description Check if all entry details are cached.
    #'
    #' @return TRUE if every key has corresponding details cached; FALSE otherwise.
    are_all_entry_details_cached = function() {
      keys <- self$all_entry_keys
      all(sapply(keys, function(key) !is.null(self$all_entry_details[[key]])))
    },

    #' @description Fetch all entry keys from the web.
    #'
    #' Retrieves entry keys in a paginated manner and updates the cache.
    fetch_all_entry_keys = function() {
      if (!is.null(self$metadata$next_url_all_entry_keys) && !is.na(self$metadata$next_url_all_entry_keys)) {
        logger::log_info("Resuming fetching all '{self$cache_name}' entry keys from cached next URL")
      } else {
        self$metadata$next_url_all_entry_keys <- self$list_all_entries_url
        logger::log_info("Begin fetching all '{self$cache_name}' entry keys from cached next URL")
      }

      current_page_number <- 0
      total_number_of_pages <- NA

      page_query <- list(page_size = self$list_all_entries_page_size)

      while (!is.null(self$metadata$next_url_all_entry_keys)) {
        current_page_number <- current_page_number + 1
        log_info_with_status(current_page_number, total_number_of_pages, "Fetching all entry keys page {self$metadata$next_url_all_entry_keys}")

        list_page_object <- fetch_web_content_as_object(self$metadata$next_url_all_entry_keys, query = page_query)
        if (is.null(list_page_object)) {
          stop(glue::glue("Failed to fetch list of entry keys for cache: {self$cache_name}"))
        }
        total_number_of_pages <- ceiling(list_page_object$count / page_query$page_size)

        results <- list_page_object$results
        keys <- sapply(results, self$key_field_extraction_func)
        self$all_entry_keys <- unique(c(self$all_entry_keys, keys))
        self$metadata$next_url_all_entry_keys <- list_page_object$`next`
        self$flush_all_entry_keys()
      }

      logger::log_info("Finished fetching all '{self$cache_name}' entry keys")
    },

    #' @description Fetch all entry details from the web.
    #'
    #' Iterates over all entry keys and fetches detailed information for each.
    fetch_all_entry_details = function() {
      num_new_keys <- 0
      total_num_keys <- length(self$all_entry_keys)
      for (i in seq_along(self$all_entry_keys)) {
        key <- self$all_entry_keys[[i]]

        if (is.null(self$all_entry_details[[key]])) {
          num_new_keys <- num_new_keys + 1

          details_url <- glue::glue(self$single_entry_details_url, entry_key = key)
          details_object <- fetch_web_content_as_object(details_url)
          # TODO: Need to figure out a way to bubble up the results so that one page failing doesn't take out the entire program.
          if (is.null(details_object)) {
            log_error_with_status(i, total_num_keys, "Failed to fetch details for key '{key}' in cache '{self$cache_name}'")
          } else {
            self$all_entry_details[[key]] <- details_object
            log_info_with_status(i, total_num_keys, "Finished fetching details for key '{key}' in cache '{self$cache_name}'")
          }
        } else {
          log_info_with_status(i, total_num_keys, "Details for key '{key}' in cache '{self$cache_name}' already cached, skipping fetch.")
        }

        if (num_new_keys > 0 && num_new_keys %% self$flush_threshold == 0) {
          self$flush_all_entry_details()
        }
      }

      self$flush_all_entry_details()
    },

    #' @description Flush cached entry keys to disk.
    #'
    #' Atomically saves the cached keys and metadata to disk.
    flush_all_entry_keys = function() {
      atomic_saveRDS(self$all_entry_keys, self$all_entry_keys_file)
      atomic_saveRDS(self$metadata, self$metadata_file)
      logger::log_info("Flushed all entry keys cache for: {self$cache_name}")
    },

    #' @description Flush cached entry details to disk.
    #'
    #' Atomically saves the cached entry details to disk.
    flush_all_entry_details = function() {
      atomic_saveRDS(self$all_entry_details, self$all_entry_details_file)
      logger::log_info("Flushed all entry details cache for: {self$cache_name}")
    }
  )
)

#' WebDetailsCacheManager class
#'
#' A manager for multiple WebDetailsCache objects.
#'
#' @field caches List of WebDetailsCache objects.
#' @field cache_dir Directory for cache files.
#' @field log_dir Directory for log files.
#' @export
WebDetailsCacheManager <- R6::R6Class("WebDetailsCacheManager", # nolint: object_name_linter, cyclocomp_linter.
  public = list(
    caches = NULL,
    cache_dir = "",
    log_dir = "logs", # default log directory

    #' @description initialize a new WebDetailsCacheManager.
    #'
    #' @param cache_dir Directory to store cache files (default "cache").
    #' @param log_dir Directory for log files (default "logs").
    initialize = function(cache_dir = "cache", log_dir = "logs") {
      self$caches <- list()
      self$cache_dir <- make_dir_if_not_exist(cache_dir)
      self$log_dir <- make_dir_if_not_exist(log_dir)
      logger::log_info("Initialized WebDetailsCacheManager with cache directory: {self$cache_dir} and log directory: {self$log_dir}")
    },

    #' @description Add a new cache to the manager.
    #'
    #' @param cache_name Unique name for the cache.
    #' @param list_all_entries_url URL for listing all entries. Expected to accept a query parameter list with page_size and return JSON containing:
    #'    - next: the next URL in the paginated results
    #'    - count: the number of results
    #'    - results: the list of entries
    #' @param key_field_extraction_func Function to extract the key field from each entry in the results.
    #' @param single_entry_details_url URL template for fetching details of a single entry. Must include a placeholder `{entry_key}` that will be replaced by the actual key.
    #' @param flush_threshold Number of entry_details to process before flushing to disk (default 100).
    #' @param list_all_entries_page_size Number of entries per page (default 1000).
    add_cache = function(cache_name, list_all_entries_url, key_field_extraction_func, single_entry_details_url, flush_threshold = 100, list_all_entries_page_size = 1000) {
      if (!is.null(self$caches[[cache_name]])) {
        stop(glue::glue("Cache '{cache_name}' already exists"))
      }

      self$caches[[cache_name]] <- WebDetailsCache$new(
        cache_name = cache_name,
        cache_dir = self$cache_dir,
        log_dir = self$log_dir,
        list_all_entries_url = list_all_entries_url,
        key_field_extraction_func = key_field_extraction_func,
        single_entry_details_url = single_entry_details_url,
        flush_threshold = flush_threshold,
        list_all_entries_page_size = list_all_entries_page_size
      )

      logger::log_info("Added cached list '{cache_name}' with URL: {list_all_entries_url}")
    },

    #' @description Build caches for all managed WebDetailsCache objects.
    #'
    #' Iterates through each cache and builds it.
    build_cache = function() {
      logger::log_info("Building web details cache for {length(self$caches)} caches")
      for (i in seq_along(self$caches)) {
        cache <- self$caches[[i]]
        log_info_with_status(i, length(self$caches), "Processing cache {cache$cache_name}")
        cache$build_cache()
        log_info_with_status(i, length(self$caches), "Finished processing cache {cache$cache_name}")
      }
      logger::log_info("Finished building web details cache for {length(self$caches)} caches")
    },

    #' @description Build caches in parallel.
    #'
    #' Processes each cache in parallel and returns a list of results.
    build_cache_threaded = function() {
      logger::log_info("Starting threaded build of web details cache for {length(self$caches)} caches")
      httr::GET("https://google.com/") # This is just to ensure the httr library is loaded properly

      # Function to process one cache.
      process_one_cache <- function(cache_name, caches) {
        tryCatch(
          {
            cache <- caches[[cache_name]]
            #' Set up a per-cache log file in the worker.
            log_file <- file.path(cache$log_dir, paste0(cache_name, ".log"))
            logger::log_appender(logger::appender_file(log_file))
            logger::log_info("Worker started for cache: {cache_name}")

            cache$build_cache()
            logger::log_info("Finished processing cache: {cache_name}")
            list(input_name = cache_name, output = "succeeded", succeeded = TRUE)
          },
          error = function(e) {
            logger::log_error("Error processing cache: {cache_name}. Exception: {e}")
            list(input_name = cache_name, output = paste0("error: ", e), succeeded = FALSE)
          }
        )
      }

      # Run the cache processing in parallel.
      results <- run_parallel_tasks("building cache", names(self$caches), process_one_cache, caches = self$caches)
      results
    },

    #' @description Clear all managed caches.
    #'
    #' Removes all caches from memory.
    clear = function() {
      self$caches <- list()
      logger::log_info("Cleared the in-memory web details cache.")
    }
  )
)

#' Create a directory if it does not exist
#'
#' @param dir_path The path of the directory.
#' @return The directory path.
#' @export
make_dir_if_not_exist <- function(dir_path) {
  if (!dir.exists(dir_path)) {
    dir.create(dir_path, recursive = TRUE, showWarnings = FALSE)
    logger::log_info("Created directory: {dir_path}")
  } else {
    logger::log_info("Directory already exists: {dir_path}")
  }
  dir_path
}

#' Atomically save an R object to an RDS file
#'
#' @param object The R object to save.
#' @param file The target file path.
#' @param compression Compression method (default "gzip").
#' @return None.
#' @export
atomic_saveRDS <- function(object, file, compression = "gzip") { # nolint: object_name_linter.
  temp_file <- paste0(file, ".tmp")
  saveRDS(object, temp_file, compress = compression)
  if (!file.rename(temp_file, file)) {
    stop("Failed to rename temp file to target file.")
  }
}

#' Compress all RDS files in a directory
#'
#' @param dir_path The directory containing RDS files.
#' @return A list of results for each file.
#' @export
compress_rds_files <- function(dir_path) {
  # Get a list of all RDS files in the cache directory.
  rds_files <- list.files(dir_path, pattern = "\\.rds$", full.names = TRUE)

  # Function to compress a single file.
  compress_file <- function(file) {
    tryCatch(
      {
        data <- readRDS(file)
        atomic_saveRDS(data, file, compression = "xz")
        list(input_name = file, output = "succeeded", succeeded = TRUE)
      },
      error = function(e) {
        list(input_name = file, output = paste0("error: ", e$message), succeeded = FALSE)
      }
    )
  }

  # Run and return the compressions in parallel.
  run_parallel_tasks("compression of RDS files in {dir_path}", rds_files, compress_file)
}

#' Stop if a condition is TRUE, with a custom error message
#'
#' @param condition A logical condition to test.
#' @param message A string message to show if the condition is TRUE.
#' @return None. Stops execution with an error if the condition is TRUE.
#' @examples
#' stopif(x > 10, "x is too large")
#'
#' @export
stopif <- function(condition, message = "Condition failed") {
  if (isTRUE(condition)) {
    stop(message, call. = FALSE)
  }
}

##' Atomically write JSON content to a file
#'
#' Writes an R object as JSON to a temporary file and then renames it to the target path,
#' ensuring that the write operation is atomic.
#'
#' @param data The R object to write as JSON.
#' @param path The file path where the JSON should be saved.
#' @param pretty Logical; if TRUE, the JSON output will be pretty-printed. Default is TRUE.
#' @param auto_unbox Logical; if TRUE, single-element vectors will be unboxed. Default is TRUE.
#' @export
atomic_write_json <- function(data, path, pretty = TRUE, auto_unbox = TRUE) {
  temp_file <- paste0(path, ".tmp")
  jsonlite::write_json(data, path = temp_file, pretty = pretty, auto_unbox = auto_unbox)

  if (!file.rename(temp_file, path)) {
    stop("Failed to rename temp file to target file.")
  }
}

##' Log an informational message with status information
#'
#' Calculates and logs the progress status and a formatted informational message.
#'
#' @param finished_count The number of completed tasks.
#' @param total_count The total number of tasks.
#' @param message A glue-formatted message to log.
#' @export
log_info_with_status <- function(finished_count, total_count, message) {
  # Calculate percent complete
  pct_done <- 0
  if (is.na(total_count)) total_count <- 0
  if (total_count > 0) { # avoid division by zero
    pct_done <- floor((finished_count / total_count) * 1000) / 10
  }
  status <- sprintf("[%2d of %2d: %5.1f%%]", finished_count, total_count, pct_done) # nolint: object_usage_linter.
  formatted_message <- glue::glue(message, .envir = parent.frame()) # nolint: object_usage_linter.
  logger::log_info("{status} {formatted_message}")
}

##'
#' CacheCountBatch class
#'
#' A class for caching results in count-based batches, storing them as JSON files.
#'
#' @field cache_name Name of the cache.
#' @field cache_dir Directory for cache files.
#' @field cache_filename File path for the cached JSON.
#' @field get_count_func Function to get total count of items.
#' @field get_batch_func Function to fetch a batch of items.
#' @field batch_size Number of items per batch.
#' @field sleep_between_calls Delay in seconds between calls.
#' @field cached_list_results Cached list of results.
#' @export
CacheCountBatch <- R6::R6Class("CacheCountBatch", # nolint: object_name_linter
  public = list(
    cache_name = "",
    cache_dir = "",
    cache_filename = "",
    get_count_func = NULL,
    get_batch_func = NULL,
    batch_size = 300,
    sleep_between_calls = 0.1,
    cached_list_results = c(),
    #' @description Initialize a new CacheCountBatch object
    #'
    #' @param cache_name Name of the cache.
    #' @param cache_dir Directory to store cache files.
    #' @param get_count_func Function returning total number of items.
    #' @param get_batch_func Function fetching a batch of items.
    #' @param batch_size Number of items per batch.
    #' @param sleep_between_calls Delay in seconds between calls.
    #' @return A new CacheCountBatch object.
    initialize = function(cache_name, cache_dir, get_count_func, get_batch_func, batch_size, sleep_between_calls) {
      self$cache_name <- cache_name
      self$cache_dir <- cache_dir
      self$get_count_func <- get_count_func
      self$get_batch_func <- get_batch_func
      self$batch_size <- batch_size
      self$sleep_between_calls <- sleep_between_calls
      self$cache_filename <- file.path(self$cache_dir, paste0(self$cache_name, "_cache", ".json"))
      rutils::make_dir_if_not_exist(self$cache_dir)
    },
    #' @description Initialize or refresh the cache by fetching and storing data.
    #'
    #' @return None. Populates the cache and writes JSON file to disk.
    init_cache = function() {
      total_results <- self$get_count_func()

      if (file.exists(self$cache_filename)) {
        self$cached_list_results <- jsonlite::read_json(self$cache_filename, simplifyVector = FALSE)
        logger::log_info("Loaded {length(self$cached_list_results)} cached entries for '{self$cache_name}'")
      } else {
        logger::log_info("Cache files for '{self$cache_name}' do not exist. Skipping load.")
      }

      if (length(self$cached_list_results) == total_results) {
        logger::log_info("Cache is already complete for '{self$cache_name}'")
        return()
      } else {
        logger::log_info("Cached data size not same as new data size.  Cleared cached data for '{self$cache_name}'")
        self$cached_list_results <- c()
      }

      # Loop to fetch results in batches
      for (start in seq(1, total_results, by = self$batch_size)) {
        batch_results <- retry_on_failure(retry_attempts = 3, delay = self$sleep_between_calls, func_to_try = self$get_batch_func, self$batch_size, start)

        self$cached_list_results <- c(self$cached_list_results, batch_results)

        # Sleep to avoid overloading NCBI servers
        log_info_with_status(length(self$cached_list_results), total_results, "Cache updated for '{self$cache_name}'")
        Sys.sleep(self$sleep_between_calls)
      }

      stopif(length(self$cached_list_results) != total_results, "Cached data size does not match expected total results.")

      # write the cache to disk
      log_info_with_status(total_results, total_results, "Cache for '{self$cache_name}' has been written to disk")
      atomic_write_json(self$cached_list_results, self$cache_filename, pretty = TRUE, auto_unbox = TRUE)
    },
    #' @description Retrieve the full cached results.
    #'
    #' @return A list of cached results.
    get_cached_list = function() {
      stopif(length(self$cached_list_results) == 0, "Cache is empty. Please initialize the cache first.")
      self$cached_list_results
    },
    #' @description Check if a key exists in the cached list.
    #'
    #' @param item_key The key to check.
    #' @return TRUE if the key is in cache; FALSE otherwise.
    is_key_in_cached_list = function(item_key) {
      # assume cache was already loaded in do_cache_list
      item_key %in% names(self$cached_list_results)
    },
    #' @description Retrieve a specific cached item by key.
    #'
    #' @param item_key The key of the item to retrieve.
    #' @return The cached item corresponding to the key.
    get_cached_item = function(item_key) {
      # assume cache was already loaded in do_cache_list
      self$cached_list_results[[item_key]]
    }
  )
)

##'
#' CacheListBatch class
#'
#' A class for caching results in list-based batches, storing them as JSON files.
#'
#' @field cache_name Name of the cache.
#' @field cache_dir Directory for cache files.
#' @field cache_filename File path for the cached JSON.
#' @field list_of_keys_to_cache List of keys to cache.
#' @field get_batch_func Function to fetch a batch of items for given keys.
#' @field batch_size Number of items per batch.
#' @field sleep_between_calls Delay in seconds between calls.
#' @field cached_list_results Cached list of results.
#' @export
CacheListBatch <- R6::R6Class("CacheListBatch", # nolint: object_name_linter, cyclocomp_linter.
  public = list(
    cache_name = "",
    cache_dir = "",
    cache_filename = "",
    list_of_keys_to_cache = NULL,
    get_batch_func = NULL,
    batch_size = 300,
    sleep_between_calls = 0.1,
    cached_list_results = c(),
    #' @description Initialize a new CacheListBatch object
    #'
    #' @param cache_name Name of the cache.
    #' @param cache_dir Directory to store cache files.
    #' @param list_of_keys_to_cache List of keys to cache.
    #' @param get_batch_func Function to fetch a batch of items for given keys.
    #' @param batch_size Number of items per batch.
    #' @param sleep_between_calls Delay in seconds between calls.
    #' @return A new CacheListBatch object.
    initialize = function(cache_name, cache_dir, list_of_keys_to_cache, get_batch_func, batch_size, sleep_between_calls) {
      self$cache_name <- cache_name
      self$cache_dir <- cache_dir
      self$list_of_keys_to_cache <- list_of_keys_to_cache
      self$get_batch_func <- get_batch_func
      self$batch_size <- batch_size
      self$sleep_between_calls <- sleep_between_calls
      self$cache_filename <- file.path(self$cache_dir, paste0(self$cache_name, "_cache", ".json"))
      rutils::make_dir_if_not_exist(self$cache_dir)
    },
    #' @description Initialize or refresh the cache by fetching and storing data for specified keys.
    #'
    #' @return None. Populates the cache and writes JSON file to disk.
    init_cache = function() {
      if (file.exists(self$cache_filename)) {
        self$cached_list_results <- jsonlite::read_json(self$cache_filename, simplifyVector = FALSE)
        logger::log_info("Loaded {length(self$cached_list_results)} cached entries for '{self$cache_name}'")
      } else {
        logger::log_info("Cache files for '{self$cache_name}' do not exist. Skipping load.")
      }

      # Remove already cached keys from the list
      missing_list_of_keys_to_cache <- setdiff(self$list_of_keys_to_cache, names(self$cached_list_results))

      total_missing_results <- length(missing_list_of_keys_to_cache)
      if (total_missing_results == 0) {
        logger::log_info("Cache is already complete for '{self$cache_name}'")
        return()
      }

      # Loop through each batch
      for (start in seq(1, total_missing_results, by = self$batch_size)) {
        # Get the current batch of gene IDs
        current_batch <- missing_list_of_keys_to_cache[start:min(start + self$batch_size - 1, total_missing_results)]

        logger::log_info("Fetching {length(current_batch)} entries for '{self$cache_name}'")

        results <- retry_on_failure(retry_attempts = 3, delay = self$sleep_between_calls, func_to_try = self$get_batch_func, current_batch)

        # ensure each requested key was returned
        missing_batch_keys <- setdiff(current_batch, names(results))
        stopif(length(missing_batch_keys) > 0, paste0("Missing batch entries for keys: ", paste(missing_batch_keys, collapse = ", ")))

        self$cached_list_results <- c(self$cached_list_results, results)

        # todo: write cache to disk
        atomic_write_json(self$cached_list_results, self$cache_filename, pretty = TRUE, auto_unbox = TRUE)
        num_remaining_keys_to_get <- length(self$list_of_keys_to_cache) - length(setdiff(self$list_of_keys_to_cache, names(self$cached_list_results)))
        log_info_with_status(num_remaining_keys_to_get, length(self$list_of_keys_to_cache), "Cache updated for '{self$cache_name}'")
      }

      missing_keys <- setdiff(self$list_of_keys_to_cache, names(self$cached_list_results))
      stopif(length(missing_keys) > 0, paste0("Missing cache entries in '{self$cache_name}' for keys: ", paste(missing_keys, collapse = ", ")))

      logger::log_info("Cache is complete for '{self$cache_name}'")
    },
    #' @description Retrieve the full cached results.
    #'
    #' @return A list of cached results.
    get_cached_list = function() {
      if (length(self$cached_list_results) == 0) {
        stop("Cache is empty. Please initialize the cache first.")
      }
      self$cached_list_results
    },
    #' @description Check if a key exists in the cached list.
    #'
    #' @param item_key The key to check.
    #' @return TRUE if the key is in cache; FALSE otherwise.
    is_key_in_cached_list = function(item_key) {
      # assume cache was already loaded in do_cache_list
      item_key %in% names(self$cached_list_results)
    },
    #' @description Retrieve a specific cached item by key.
    #'
    #' @param item_key The key of the item to retrieve.
    #' @return The cached item corresponding to the key.
    get_cached_item = function(item_key) {
      # assume cache was already loaded in do_cache_list
      self$cached_list_results[[item_key]]
    }
  )
)

#' Compare two JSON files containing lists
#'
#' @param file1 Path to the first JSON file.
#' @param file2 Path to the second JSON file.
#' @return A list with elements 'common', 'unique_to_file1', and 'unique_to_file2'.
#' @examples
#' result <- compare_json_lists(
#'   "data/accessions_of_interest_from_code_api.json",
#'   "data/accessions_of_interest_from_web_search.json"
#' )
#' @export
compare_json_lists <- function(file1, file2) {
  # Load the JSON files
  if (!file.exists(file1) || !file.exists(file2)) {
    return(list())
  }

  list1 <- jsonlite::fromJSON(file1)
  list2 <- jsonlite::fromJSON(file2)

  # Ensure the inputs are vectors
  if (!is.vector(list1) || !is.vector(list2)) {
    stop("Both JSON files must contain lists or arrays.")
  }

  # Find common, unique, and missing elements
  common_elements <- intersect(list1, list2)
  unique_to_file1 <- setdiff(list1, list2)
  unique_to_file2 <- setdiff(list2, list1)

  # Print the results in a nicer format with counts
  cat("Comparison Results:\n\n")

  cat("Common elements (in both files):", length(common_elements), "\n")
  if (length(common_elements) > 0) {
    cat(paste(common_elements, collapse = ", "), "\n\n")
  } else {
    cat("None\n\n")
  }

  cat("Unique to", file1, ":", length(unique_to_file1), "\n")
  if (length(unique_to_file1) > 0) {
    cat(paste(unique_to_file1, collapse = ", "), "\n\n")
  } else {
    cat("None\n\n")
  }

  cat("Unique to", file2, ":", length(unique_to_file2), "\n")
  if (length(unique_to_file2) > 0) {
    cat(paste(unique_to_file2, collapse = ", "), "\n\n")
  } else {
    cat("None\n\n")
  }

  # Return the results as a list
  list(
    common = common_elements,
    unique_to_file1 = unique_to_file1,
    unique_to_file2 = unique_to_file2
  )
}

 #' Executes a function repeatedly until it succeeds or the maximum number of attempts is reached.
 #'
 #' @param retry_attempts The maximum number of attempts to execute the function.
 #' @param delay The time in seconds to wait between attempts.
 #' @param func_to_try A function (with no arguments) that is attempted.
 #' @param ... Additional arguments to pass to `func_to_try`.
 #'
 #' @return The result of the function if a successful execution occurs, or NULL if all attempts fail.
 #' @examples
 #' retry_on_failure(3, 1, function() {
 #'   some_unreliable_function()
 #' })
 #' @export
retry_on_failure <- function(retry_attempts, delay, func_to_try, ...) {
  attempt <- 1
  result <- NULL

  # Loop to retry the function until success or maximum attempts reached.
  while (attempt <= retry_attempts) {
    tryCatch(
      {
        result <- func_to_try(...) # Attempt to execute the provided function.
        break # Exit loop if the function executes successfully.
      },
      error = function(e) {
        Sys.sleep(delay) # Wait for the specified delay before retrying.
      }
    )
    attempt <- attempt + 1
  }

  # Return the result from the first successful attempt, or NULL if all attempts fail.
  result
}

#' Fetch web content as plain text with retry support
#'
#' This function sends an HTTP GET request to a specified URL with optional query parameters.
#' If the request fails, it will retry up to the number of attempts specified.
#'
#' @param url A character string specifying the URL to fetch.
#' @param query A named list of query parameters to include in the request (default is an empty list).
#' @param retry_attempts An integer. Number of retry attempts on failure (default is 0).
#' @param delay A numeric. Number of seconds to wait between retries (default is 0).
#'
#' @return A character string with the raw response content, or NULL if the request fails.
#' @export
fetch_web_content <- function(url, query = list(), retry_attempts = 0, delay = 0) {
  retry_on_failure(retry_attempts = retry_attempts, delay = delay, func_to_try = function() {
    res <- httr::GET(url, query = query)
    if (httr::http_error(res)) {
      logger::log_error("Failed to fetch content from {url}. Status: {status_code(res)}")
      stop()
    }
    httr::content(res, as = "text", encoding = "UTF-8")
  })
}

#' Fetch and parse web content as a JSON object
#'
#' This function fetches content from a URL and parses it as a JSON object.
#'
#' @param url A character string specifying the URL to fetch.
#' @param query A named list of query parameters to include in the request (default is an empty list).
#' @param retry_attempts An integer. Number of retry attempts on failure (default is 0).
#' @param delay A numeric. Number of seconds to wait between retries (default is 0).
#'
#' @return A parsed JSON object (as a list), or NULL if the fetch or parsing fails.
#' @export
fetch_web_content_as_object <- function(url, query = list(), retry_attempts = 0, delay = 0) {
  page_content <- fetch_web_content(url, query)
  if (is.null(page_content)) {
    return(NULL)
  }
  jsonlite::fromJSON(page_content, simplifyVector = FALSE)
}

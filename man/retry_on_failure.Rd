% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/utils.R
\name{retry_on_failure}
\alias{retry_on_failure}
\title{Executes a function repeatedly until it succeeds or the maximum number of attempts is reached.}
\usage{
retry_on_failure(retry_attempts, delay, func_to_try, ...)
}
\arguments{
\item{retry_attempts}{The maximum number of attempts to execute the function.}

\item{delay}{The time in seconds to wait between attempts.}

\item{func_to_try}{A function (with no arguments) that is attempted.}

\item{...}{Additional arguments to pass to \code{func_to_try}.}
}
\value{
The result of the function if a successful execution occurs, or NULL if all attempts fail.
}
\description{
Executes a function repeatedly until it succeeds or the maximum number of attempts is reached.
}
\examples{
retry_on_failure(3, 1, function() {
  some_unreliable_function()
})
}

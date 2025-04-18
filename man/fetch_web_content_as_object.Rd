% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/utils.R
\name{fetch_web_content_as_object}
\alias{fetch_web_content_as_object}
\title{Fetch web content and convert it to an R object}
\usage{
fetch_web_content_as_object(url, query = list())
}
\arguments{
\item{url}{The URL to fetch content from.}

\item{query}{A list of query parameters.}
}
\value{
The parsed JSON object, or NULL if the fetch failed.
}
\description{
Fetch web content and convert it to an R object
}

#' @name commit_stats
#'
#' @title Get and summarize repository statistics from GitHub
#'
#' @description These functions allow the user to query the GitHub API and
#'   produce a comprehensive summary of commit activity for each R package
#'   repository. The main workhorse function is `summarize_account_activity`
#'   which calls all other functions internally to produce a summary of GitHub R
#'   repository activity.
#'
#' @param username `character(1)` The GitHub username
#'
#' @param org `character(1)` optional. The organization account for which to
#'   search repositories for.
#'
#' @param github_token `gh_pat` The personal access token obtained from GitHub.
#'   By default, `gh::gh_token()` is used.
#'
#' @returns `get_repositories`: A list of repositories for the corresponding
#'   account or organization
#'
#' @examples
#' if (interactive()) {
#'     gitcreds::gitcreds_set()
#'     summarize_account_activity(
#'         username = "LiNk-NY",
#'         org = "waldronlab",
#'         start_date = "2023-08-31",
#'         end_date = "2024-09-01"
#'     )
#' }
#' @export
get_repositories <- function(username, org, github_token = gh::gh_token()) {
    message("Finding repositories for ", username, "...")
    repos <- list()
    page <- 1
    has_more <- TRUE

    while (has_more) {
        if (!missing(org)) {
            endpoint <- "GET /orgs/{org}/repos"
            username <- org
        } else {
            endpoint <- "GET /users/{username}/repos"
        }
        new_repos <- gh::gh(
            endpoint,
            username = username,
            org = username,
            page = page,
            .token = github_token
        )
        if (length(new_repos)) {
            repos <- c(repos, new_repos)
            page <- page + 1
        } else {
            has_more <- FALSE
        }
    }
    repos
}

#' @rdname commit_stats
#'
#' @param repo_list `list` A list as obtained from `get_repositories`
#'
#' @returns `filter_r_repos`: A list of filtered repositories containing R code
#'
#' @export
filter_r_repos <-
    function(repo_list, username, org, github_token = gh::gh_token())
{
    message("Identifying R repositories...")
    purrr::map_df(repo_list, function(repo, username, org, github_token) {
        if (!missing(org))
            username <- org
        languages <- gh::gh(
            "GET /repos/{owner}/{repo}/languages",
            owner = username,
            repo = repo$name,
            .token = github_token
        )
        if ("R" %in% names(languages)) {
            tibble::tibble(
                full_name = repo$full_name,
                name = repo$name,
                description =
                    ifelse(is.null(repo$description), NA, repo$description),
                stars = repo$stargazers_count,
                forks = repo$forks_count,
                last_updated = repo$updated_at,
                is_fork = repo$fork,
                default_branch = repo$default_branch,
                r_percentage =
                    round(languages$R / sum(unlist(languages)) * 100, 1)
            )
        }
    }, username = username, org = org, github_token = github_token)
}

#' @rdname commit_stats
#'
#' @param repos_df `tibble` A tibble of filtered R repositories as obtained from
#'   `filter_r_repos`
#'
#' @param start_date,end_date `character(1)` The start and end dates delimiting
#'   commit searches in the `YYYY-MM-DD` format
#'
#' @returns `repository_commits`: A `list` of commits for each row in the
#'   `repos_df` input
#'
#' @export
repository_commits <- function(
    repos_df, username, org, github_token = gh::gh_token(),
    start_date, end_date
) {
    message("Fetching commits for ", nrow(repos_df), " R repositories...")
    all_commits <- list()
    if (missing(org))
        org <- username
    for (i in seq_len(nrow(repos_df))) {
        repo <- repos_df$full_name[i]
        message("Processing ", repo, " (", i, "/", nrow(repos_df), ")")
        commits <- tryCatch({
            gh::gh(
                "GET /repos/{owner}/{repo}/commits",
                author = username,
                owner = org,
                repo = repos_df$name[i],
                since = start_date,
                until = end_date,
                .token = github_token
            )
        }, error = function(e) {
            warning("Error fetching commits for ", repo, ": ", e$message)
            return(list())
        })
        repo_commits <- purrr::map(commits, function(commit) {
            list(
                repository = repo,
                sha = commit$sha,
                author = commit$commit$author$name,
                date = commit$commit$author$date,
                message = commit$commit$message,
                changes = tryCatch({
                    commit_detail <- gh::gh(
                        "GET /repos/{owner}/{repo}/commits/{sha}",
                        owner = org,
                        repo = repos_df$name[i],
                        sha = commit$sha,
                        since = start_date,
                        until = end_date,
                        .token = github_token
                    )
                    list(
                        additions = commit_detail$stats$additions,
                        deletions = commit_detail$stats$deletions,
                        files_changed = length(commit_detail$files)
                    )
                }, error = function(e) {
                    list(additions = NA, deletions = NA, files_changed = NA)
                })
            )
        })
        all_commits <- c(all_commits, repo_commits)
    }
    all_commits
}

#' @rdname commit_stats
#'
#' @param commits_list `list` The output of `repository_commits` that contains
#'   commit details for each repository
#'
#' @returns `repository_summary`: A `list` of `tibbles` that summarize activity
#'   in the associated `repositories` for the `username` / `org` account
#'
#' @export
repository_summary <- function(
    commits_list, repositories, username, org, start_date, end_date
) {
    if (missing(org))
        org <- username
    commit_stats <- tibble::tibble(
        repository = map_chr(commits_list, "repository"),
        author = map_chr(commits_list, "author"),
        date = map_chr(commits_list, "date"),
        additions = map_dbl(commits_list, function(x) x$changes$additions),
        deletions = map_dbl(commits_list, function(x) x$changes$deletions),
        files_changed =
            map_dbl(commits_list, function(x) x$changes$files_changed)
    )
    repo_summary <- commit_stats |>
        group_by(repository) |>
        summarise(
            total_commits = n(),
            unique_authors = n_distinct(author),
            total_additions = sum(additions, na.rm = TRUE),
            total_deletions = sum(deletions, na.rm = TRUE),
            total_files_changed = sum(files_changed, na.rm = TRUE)
        )
    summary <- list(
        account_info = tibble::tibble(
            name = username, org = org, start = start_date, end = end_date
        ),
        repositories = repositories,
        repository_stats = repo_summary,
        commit_details = commit_stats,
        overall_stats = tibble::tibble(
            total_repositories = nrow(repositories),
            total_commits = nrow(commit_stats),
            unique_authors = n_distinct(commit_stats$author),
            total_additions = sum(commit_stats$additions, na.rm = TRUE),
            total_deletions = sum(commit_stats$deletions, na.rm = TRUE),
            total_files_changed = sum(commit_stats$files_changed, na.rm = TRUE)
        )
    )
    class(summary) <- c("commit_summary", class(summary))
    summary
}

#' @rdname commit_stats
#'
#' @importFrom tibble tibble
#' @importFrom gh gh gh_token
#' @importFrom purrr map_df map_chr map_dbl map
#'
#' @returns `summarize_account_activity`: A `list` of `tibbles` that summarize
#'   activity in the associated `repositories` for the `username` / `org`
#'   account
#'
#' @export
summarize_account_activity <- function(
    username,
    org,
    start_date,
    end_date,
    github_token = gh::gh_token()
) {
    start_date <- as.POSIXct(start_date) |> format("%Y-%m-%dT%H:%M:%SZ")
    end_date <- as.POSIXct(end_date) |> format("%Y-%m-%dT%H:%M:%SZ")
    # Step 1: Find all repositories for the account
    repos <- get_repositories(
        username = username, org = org, github_token = github_token
    )
    # Step 2: Filter for R repositories
    r_repos <- filter_r_repos(
        repos, username = username, org = org, github_token = github_token
    )
    if (!nrow(r_repos))
        stop("No R package repositories found in 'username' / 'org' account")
    # Step 3: Fetch commits for each R repository
    commits_list <- repository_commits(
        repos_df = r_repos, username = username, org = org,
        github_token = github_token,
        start_date = start_date, end_date = end_date
    )
    # Step 4: Summarize statistics
    repository_summary(
        commits_list = commits_list,
        repositories = r_repos, username = username, org = org,
        start_date = start_date, end_date = end_date
    )
}

# Print method for nice output

#' @rdname commit_stats
#'
#' @export
print.commit_summary <- function(x) {
    cat("\nR Development Activity Analysis\n")
    cat("============================\n")
    cat("Username:",x$account_info$name, "\n")
    if (length(x$account_info$org))
        cat("Org:", x$account_info$org, "\n")
    cat(
        "Period:", x$account_info$start, "to", x$account_info$end, "\n\n"
    )
    cat("Overall Statistics:\n")
    cat(sprintf("- R Repositories: %d\n", x$overall_stats$total_repositories))
    cat(sprintf("- Total Commits: %d\n", x$overall_stats$total_commits))
    cat(sprintf("- Unique Contributors: %d\n", x$overall_stats$unique_authors))
    cat(sprintf("- Lines Added: %d\n", x$overall_stats$total_additions))
    cat(sprintf("- Lines Deleted: %d\n", x$overall_stats$total_deletions))
    cat(sprintf("- Files Changed: %d\n\n", x$overall_stats$total_files_changed))

    cat("Repository Summary:\n")
    print(x$repository_stats)
}

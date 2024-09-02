# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Git::Clone;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Mojo::Util 'trim';

use OpenQA::Utils qw(run_cmd_with_log_return_error);
use Mojo::File;
use Time::Seconds 'ONE_HOUR';

sub register ($self, $app, @) {
    $app->minion->add_task(git_clone => \&_git_clone_all);
}

# $clones is a hashref with paths as keys and urls to git repos as values.
# The urls may also refer to a branch via the url fragment.
# If no branch is set, the default branch of the remote (if target path doesn't exist yet)
# or local checkout is used.
# If the target path already exists, an update of the specified branch is performed,
# if the url matches the origin remote.

sub _git_clone_all ($job, $clones) {
    my $app = $job->app;
    my $job_id = $job->id;

    my $retry_delay = {delay => 30 + int(rand(10))};
    # Don't interfere with any needle task
    return $job->retry({delay => 5})
      unless my $needle_guard = $app->minion->guard('limit_needle_task', 2 * ONE_HOUR);
    # Prevent multiple git_clone tasks for the same path to run in parallel
    my @guards;
    for my $path (sort keys %$clones) {
        $path = Mojo::File->new($path)->realpath if -e $path;    # resolve symlinks
        my $guard = $app->minion->guard("git_clone_${path}_task", 2 * ONE_HOUR);
        return $job->retry($retry_delay) unless $guard;
        push @guards, $guard;
    }

    my $log = $app->log;
    my $ctx = $log->context("[#$job_id]");

    # iterate clones sorted by path length to ensure that a needle dir is always cloned after the corresponding casedir
    for my $path (sort { length($a) <=> length($b) } keys %$clones) {
        my $url = $clones->{$path};
        die "Don't even think about putting '..' into '$path'." if $path =~ /\.\./;
        eval { _git_clone($app, $job, $ctx, $path, $url) };
        next unless my $error = $@;
        my $max_retries = $ENV{OPENQA_GIT_CLONE_RETRIES} // 10;
        return $job->retry($retry_delay) if $job->retries < $max_retries;
        return $job->fail($error);
    }
}

sub _git_clone ($app, $job, $ctx, $path, $url) {
    my $git = OpenQA::Git->new(app => $app, dir => $path);
    $ctx->debug(qq{Updating $path to $url});
    $url = Mojo::URL->new($url);
    my $requested_branch = $url->fragment;
    $url->fragment(undef);

    # An initial clone fetches all refs, we are done
    return $git->clone_url($url) unless -d $path;

    my $origin_url = $git->get_origin_url;
    if ($url ne $origin_url) {
        $ctx->warn("Local checkout at $path has origin $origin_url but requesting to clone from $url");
        return;
    }

    die "NOT updating dirty git checkout at $path" if !$git->is_workdir_clean();

    unless ($requested_branch) {
        my $remote_default = $git->get_remote_default_branch($url);
        $requested_branch = $remote_default;
        $ctx->debug(qq{Remote default branch $remote_default});
    }

    my $current_branch = $git->get_current_branch;
    # updating default branch (including checkout)
    $git->fetch($requested_branch);
    $git->reset_hard($requested_branch) if ($requested_branch eq $current_branch);
}

1;

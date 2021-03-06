package Minion::Banana;

use Mojo::Base 'Mojo::EventEmitter';
use Mojo::Pg;
use Mojo::Pg::Migrations;
use Mojo::JSON 'j';
use Mojo::IOLoop;

use Devel::GlobalDestruction ();
use Safe::Isa '$_isa';

# see Importer.pm
our @EXPORT_OK = (qw[parallel sequence]);

has migrations => sub {
  Mojo::Pg::Migrations->new(pg => shift->pg, name => 'minion_banana')->from_data;
};
has minion => sub { die 'a minion attribute is required' };
has pg => sub {
  my $backend = shift->minion->backend;
  die 'a pg attribute is required'
    unless $backend->$_isa('Minion::Backend::Pg');
  return $backend->pg;
};

sub app { shift->minion->app }

sub attach {
  my ($self, $minion) = @_;
  $self->minion($minion) if $minion;
  $self->migrations->migrate;
  $self->minion->on(worker => \&_worker);
  $self->app->helper(minion_banana => sub { $self });
  return $self;
}

sub enable_jobs {
  my ($self, $jobs, $cb) = @_;
  $jobs = [$jobs ? $jobs : ()] unless ref $jobs;
  return unless @$jobs;
  my $minion = $self->minion;
  for my $id (@$jobs) {
    $self->minion->job($id)->retry({queue => 'default'});
  }
  my $query = <<'  SQL';
    UPDATE minion_banana_jobs
    SET status='enabled'
    WHERE id=any(?) AND status='waiting'
  SQL
  return $self->pg->db->query($query, $jobs)->rows unless $cb;
  $self->pg->db->query($query, $jobs, sub {
    my ($db, $err, $results) = @_;
    return $self->$cb("Enable jobs error: $err") if $err;
    $self->$cb(undef, $results ? $results->rows : undef);
  });
}

sub enqueue {
  my ($self, $jobs) = @_;
  my $group = $self->_enqueue_group;
  $self->_enqueue($group, $jobs, []);
  return $group;
}

sub group_status {
  my ($self, $group, $cb) = @_;
  my $sql = <<'  SQL';
    SELECT job.id, job.status, json_agg(parents.parent_id) AS parents
    FROM minion_banana_groups groups
    LEFT JOIN minion_banana_jobs job ON job.group_id=groups.id
    LEFT JOIN minion_banana_job_deps parents ON job.id=parents.job_id
    WHERE groups.id=?
    GROUP BY job.id, parents.parent_id
    ORDER BY job.id ASC
  SQL
  return $self->pg->db->query($sql, $group)->expand->hashes unless $cb;
  $sql->pg->db->query($sql, $group, sub {
    my ($db, $err, $results) = @_;
    return $cb->($err, undef) if $err;
    $cb->(undef, $results->expand->hashes);
  });
}

sub jobs_ready {
  my $cb = (ref $_[-1] && ref $_[-1] eq 'CODE') ? pop : undef;
  my ($self, $group) = @_; # $group is optional
  my $query = <<'  SQL';
    SELECT DISTINCT jobs.id
    FROM minion_banana_jobs jobs
    LEFT JOIN minion_banana_job_deps parents ON jobs.id=parents.job_id
    LEFT JOIN minion_banana_jobs parent ON parents.parent_id=parent.id
    WHERE
      jobs.status='waiting'
      AND (parent.status IS NULL OR parent.status='finished')
      AND (jobs.group_id = $1 OR $1 IS NULL)
    ORDER BY jobs.id ASC
  SQL
  return $self->pg->db->query($query, $group)->arrays->flatten->to_array unless $cb;
  $self->pg->db->query($query, $group, sub {
    my ($db, $err, $results) = @_;
    return $self->$cb("Jobs ready check error: $err", undef) if $err;
    $self->$cb(undef, $results->arrays->flatten->to_array);
  });
}

sub manage {
  my $self = shift;
  my $jobs = $self->jobs_ready;
  $self->enable_jobs($jobs);
  my $cb = $self->pg->pubsub->listen(minion_banana => sub {
    my ($pubsub, $payload) = @_;
    my $data = j $payload;
    return $self->_update($data->{job}, 0, sub {})
      unless $data->{success};
    Mojo::IOLoop->delay(
      sub { $self->_update($data->{job}, 1, shift->begin) },
      sub {
        my ($delay, $err, $results) = @_;
        die $err if $err;
        return unless $results->rows;
        $self->jobs_ready($results->hash->{group}, shift->begin);
      },
      sub {
        my ($delay, $err, $jobs) = @_;
        die $err if $err;
        $self->emit(ready => $jobs);
      },
    )->catch(sub {
      return if Devel::GlobalDestruction::in_global_destruction;
      $self->emit(error => $_[1]);
    });
  });
  Mojo::IOLoop->singleton->once(finish => sub {
    return if Devel::GlobalDestruction::in_global_destruction;
    $self->pg->pubsub->unlisten(minion_banana => $cb);
  });
  Mojo::IOLoop->start;
}

sub new {
  my $self = shift->SUPER::new(@_);
  $self->on(ready => sub {
    my ($self, $jobs) = @_;
    $self->enable_jobs($jobs, sub{});
  });
  return $self;
}

sub _dequeue {
  my ($worker, $job) = @_;
  $job->on(finished => \&_finished);
  $job->on(failed   => \&_failed);
}

sub _enqueue {
  my ($self, $group, $job, $parents) = @_;
  $parents ||= [];
  if ($job->$_isa('Minion::Banana::Sequence')) {
    for my $j ( @$job ) {
      $parents = $self->_enqueue($group, $j, $parents);
    }
    return $parents;
  } elsif ($job->$_isa('Minion::Banana::Parallel')) {
    my @ids;
    for my $j ( @$job ) {
      my $ids = $self->_enqueue($group, $j, $parents);
      push @ids, @$ids;
    }
    return \@ids;
  } else {
    return $self->_enqueue_job($group, $job, $parents); # this is always a leaf in the graph
  }
}

sub _enqueue_group {
  return shift->pg->db->query("INSERT INTO minion_banana_groups DEFAULT VALUES RETURNING id")->hash->{id};
}

sub _enqueue_job {
  my ($self, $group, $job, $parents) = @_;
  $job->[2]{queue} = 'waitdeps';
  my $id = $self->minion->enqueue(@$job);
  $self->pg->db->query('INSERT INTO minion_banana_jobs (id, group_id) VALUES  (?,?)', $id, $group);
  $self->pg->db->query(<<'  SQL', $id, $parents) if @$parents;
    INSERT INTO minion_banana_job_deps (job_id, parent_id)
    SELECT ?, parent
    FROM unnest(?::bigint[]) g(parent)
  SQL
  return [$id];
}

sub _failed {
  my ($job, $err) = @_;
  $job->app->minion_banana->_notify($job, 0);
}

sub _finished {
  my ($job, $result) = @_;
  $job->app->minion_banana->_notify($job, 1);
}

sub _notify {
  my ($self, $job, $success) = @_;
  $self->pg->pubsub->notify(minion_banana => j({job => $job->id, success => $success ? \1 : \0}));
}

sub _update {
  my ($self, $job, $success, $cb) = @_;
  my $query = <<'  SQL';
    UPDATE minion_banana_jobs
    SET status=?
    WHERE id=? AND status='enabled'
    RETURNING id, group_id, status
  SQL
  my @args = ($success ? 'finished' : 'failed', $job);
  return $self->pg->db->query($query, @args) unless $cb;
  $self->pg->db->query($query, @args, sub {
    my ($db, $err, $results) = @_;
    return $self->$cb("Update error: $err", undef) if $err;
    $self->$cb(undef, $results);
  });
}

sub _worker {
  my ($minion, $worker) = @_;
  $worker->on(dequeue => \&_dequeue);
}

# classes and functions

{
  package Minion::Banana::Parallel;
  use Mojo::Base 'Mojo::Collection';

  package Minion::Banana::Sequence;
  use Mojo::Base 'Mojo::Collection';
}

sub parallel { Minion::Banana::Parallel->new(@_) }
sub sequence { Minion::Banana::Sequence->new(@_) }

'BA-NA-NA!';

=head1 NAME

Minion::Banana - Motivate your Minions! Higher level Minion management.

=head1 SYNOPSIS

  use Importer 'Minion::Banana' => qw/parallel sequence/;

  $app->plugin(Minion => \%backend);
  $app->minion->add_task(mytask => sub { ... });

  $app->plugin('Minion::Banana');
  $app->minion_banana->enqueue(
    sequence(
      [mytask => \@args],
      parallel(
        [mytask => \@args],
        [mytask => \@args],
      ),
      [mytask => \@args],
    )
  );

  # TODO add banana/manage commands
  $ ./myapp.pl minion banana manage

=head1 DESCRIPTION

L<Minion::Banana> is a job manager for L<Minion>.
It is especially built for handling job dependencies, it might be useful for more than that.

=head1 CONVENIENCE FUNCTIONS

Users may import the following convenience functions if desired.
See L<Importer> for details.

=head2 parallel

Convenience function constructor for L<Minion::Banana::Parallel>

=head2 sequence

Convenience function constructor for L<Minion::Banana::Sequence>

=head1 EVENTS

L<Minion::Banana> inherits all of the events from L<Mojo::EventEmitter> and emits the following new ones.

=head2 ready

Emitted when jobs in a group become ready to perform.

=head1 ATTRIBUTES

L<Minion::Banana> inherits all of the attributes from L<Mojo::EventEmitter> and implements the following new ones.

=head2 migrations

An instance of L<Mojo::Pg::Migrations>.

=head2 minion

An instance of L<Minion>, required.

=head2 pg

An instance of L<Mojo::Pg> taken from L</minion> if possible and not otherwise specified.

=head1 METHODS

L<Minion::Banana> inherits all of the methods from L<Mojo::EventEmitter> and implements the following new ones.

=head2 app

Convenience method to access the application object from L</minion>.

=head2 attach

This method should be called once in the application startup to correctly setup necessary functionality.
It needs to be called after the L<Mojolicious::Plugin::Minion> is loaded.
It is called for you by L<Mojolicious::Plugin::Minion::Banana>.

=head2 enable_jobs

Takes an array reference of job ids and "retries" them, moving them from the parking lot queue to an active queue.

=head2 enqueue

Enqueue one or more jobs as a group, these can be either an array reference representing a call to L<Minion/enqueue> or a L<Minion::Banana::Parallel> or L<Minion::Banana::Sequence> of jobs.

=head2 group_status

Given a group id, returns a data structure with Minion::Banana's view of the contained jobs.

=head2 jobs_ready

Returns an array reference of job ids that are ready to be enabled (ie. whose dependencies are satisfied).
Optionally takes a group id to limit the returned jobs to those in a particular group.

=head2 manage

Run the actual job manager.
This method starts the L<Mojo::IOLoop> and should not be called within a running loop.
Stop the loop in order to stop the manager.

=head2 new

Creates and returns a new instance of L<Minion::Banana>.
Also attaches a default subscriber to the L</ready> event which immediately calls L</enable_jobs>.

=head1 SEE ALSO

=over

=item *

L<Mojolicious> - Real-time web framework

=item *

L<Minion> - The L<Mojolicious> job queue

=item *

L<Minion::Notifier> - A related project for notifying on job state changes.

=back

=head1 SOURCE REPOSITORY

L<http://github.com/jberger/Minion-Notifier>

=head1 AUTHOR

Joel Berger, E<lt>joel.a.berger@gmail.comE<gt>

=head1 DEVELOPMENT SPONSORED BY

ServerCentral - L<http://servercentral.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2016 by Joel Berger
This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__DATA__

@@ minion_banana
-- 1 up
CREATE TABLE minion_banana_groups (
  id BIGSERIAL PRIMARY KEY,
  created TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE minion_banana_jobs (
  id BIGINT PRIMARY KEY,
  group_id BIGINT REFERENCES minion_banana_groups(id) ON DELETE CASCADE,
  status TEXT DEFAULT 'waiting'
);
CREATE TABLE minion_banana_job_deps (
  job_id BIGINT REFERENCES minion_banana_jobs(id) ON DELETE CASCADE,
  parent_id BIGINT REFERENCES minion_banana_jobs(id),
  UNIQUE (job_id, parent_id)
);
--1 down;
DROP TABLE IF EXISTS minion_banana_job_deps;
DROP TABLE IF EXISTS minion_banana_jobs;
DROP TABLE IF EXISTS minion_banana_groups;


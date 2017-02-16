package Koha::Illbackends::FreeForm::Base;

# Copyright PTFS Europe 2014
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;
use DateTime;
use Koha::Illrequestattribute;

=head1 NAME

Koha::Illrequest::Backend::FreeForm::Base - Koha ILL Backend: FreeForm

=head1 SYNOPSIS

Koha ILL implementation for the "FreeForm" backend.

=head1 DESCRIPTION

=head2 Overview

We will be providing the Abstract interface which requires we implement the
following methods:
- create        -> initial placement of the request for an ILL order
- confirm       -> confirm placement of the ILL order (No-op in FreeForm)
- cancel        -> request an already 'confirm'ed ILL order be cancelled
- status_graph  -> return a hashref of additional statuses
- name          -> return the name of this backend
- metadata      -> return mapping of fields from requestattributes

=head2 On the FreeForm backend

The FreeForm backend is a simple backend that is supposed to act as a
fallback.  It provides the end user with some mandatory fields in a form as
well as the option to enter additional fields with arbitrary names & values.

=head1 API

=head2 Class Methods

=cut

sub update_status {}

=head3 new

  my $backend = Koha::Illrequest::Backend::FreeForm->new;

=cut

sub new {
    # -> instantiate the backend
    my ( $class ) = @_;
    my $self = {};
    bless( $self, $class );
    return $self;
}

=head3 name

Return the name of this backend.

=cut

sub name {
    return "FreeForm";
}

=head3 metadata

Return a hashref containing canonical values from the key/value
illrequestattributes store.

=cut

sub metadata {
    my ( $self, $request ) = @_;
    my $attrs = $request->illrequestattributes;
    return {
        Title      => $attrs->find({ type => 'title' })->value,
        Author     => $attrs->find({ type => 'author' })->value,
        Identifier => $attrs->find({ type => 'identifier' })->value,
    }
}

=head3 status_graph

This backend provides no additional actions on top of the core_status_graph.

=cut

sub status_graph {
    return {};
}

=head3 create

  my $response = $backend->create({ params => $params });

We just want to generate a form that allows the end-user to associate key
value pairs in the database.

=cut

sub create {
    my ( $self, $params ) = @_;
    my $other = $params->{other};
    my $stage = $other->{stage};
    if ( !$stage || $stage eq 'init' ) {
        # We simply need our template .INC to produce a form.
        return {
            error   => 0,
            status  => '',
            message => '',
            method  => 'create',
            stage   => 'form',
            value   => $params,
        };
    } elsif ( $stage eq 'form' ) {
	# Received completed details of form.  Validate and create request.

        ## Validate
        my ( $brw_count, $brw )
            = _validate_borrower($other->{'cardnumber'});
        my $result = {
            status  => "",
            message => "",
            error   => 1,
            value   => {},
            method  => "create",
            stage   => "init",
        };
	if ( !$other->{'title'} ) {
            $result->{status} = "missing_title";
            $result->{value} = $params;
            return $result;
	} elsif ( !$other->{'author'} ) {
            $result->{status} = "missing_author";
            $result->{value} = $params;
            return $result;
	} elsif ( !$other->{'identifier'} ) {
            $result->{status} = "missing_identifier";
            $result->{value} = $params;
            return $result;
        } elsif ( !$other->{'branchcode'} ) {
            $result->{status} = "missing_branch";
            $result->{value} = $params;
            return $result;
        } elsif ( !Koha::Libraries->find($other->{'branchcode'}) ) {
            $result->{status} = "invalid_branch";
            $result->{value} = $params;
            return $result;
        } elsif ( $brw_count == 0 ) {
            $result->{status} = "invalid_borrower";
            $result->{value} = $params;
            return $result;
        } elsif ( $brw_count > 1 ) {
            # We must select a specific borrower out of our options.
            $params->{brw} = $brw;
            $result->{value} = $params;
            $result->{stage} = "borrowers";
            $result->{error} = 0;
            return $result;
        };

        ## Create request

        # ...Populate Illrequest
        my $request = $params->{request};
        $request->borrowernumber($brw->borrowernumber);
        $request->branchcode($params->{other}->{branchcode});
        $request->status('NEW');
	$request->backend($params->{other}->{backend});
        $request->placed(DateTime->now);
        $request->updated(DateTime->now);
        $request->store;
        # ...Populate Illrequestattributes
        # generate $request_details
        # The core fields
        # + each additional field added by user
        my $request_details = {
            title      => $params->{other}->{title},
            author     => $params->{other}->{author},
            identifier => $params->{other}->{identifier},
        };
        while ( my ( $type, $value ) = each %{$request_details} ) {
            Koha::Illrequestattribute->new({
                illrequest_id => $request->illrequest_id,
                type          => $type,
                value         => $value,
            })->store;
        }

        ## -> create response.
        return {
            error   => 0,
            status  => '',
            message => '',
            method  => 'create',
            stage   => 'commit',
            next    => 'illview',
            value   => $request_details,
        };
    } else {
	# Invalid stage, return error.
        return {
            error   => 1,
            status  => 'unknown_stage',
            message => '',
            method  => 'create',
            stage   => $params->{stage},
            value   => {},
        };
    }
}

=head3 confirm

  my $response = $backend->confirm({ params => $params });

Confirm the placement of the previously "selected" request (by using the
'create' method).

In the FreeForm backend we only want to display a bit of text to let staff
confirm that they have taken the steps they need to take to "confirm" the
request.

=cut

sub confirm {
    my ( $self, $params ) = @_;
    my $stage = $params->{other}->{stage};
    if ( !$stage || $stage eq 'init' ) {
        # We simply need our template .INC to produce a text block.
        return {
            method  => 'confirm',
            stage   => 'confirm',
            value   => $params,
        };
    } elsif ( $stage eq 'confirm' ) {
        my $request = $params->{request};
        $request->orderid($request->illrequest_id);
        $request->status("REQ");
        $request->store;
        # ...then return our result:
        return {
            method   => 'confirm',
            stage    => 'commit',
            next     => 'illview',
            value    => {},
        };
    } else {
	# Invalid stage, return error.
        return {
            error   => 1,
            status  => 'unknown_stage',
            message => '',
            method  => 'confirm',
            stage   => $params->{stage},
            value   => {},
        };
    }
}

=head3 cancel

  my $response = $backend->cancel({ params => $params });

We will attempt to cancel a request that was confirmed.

In the FreeForm backend this simply means displaying text to the librarian
asking them to confirm they have taken all steps needed to cancel a confirmed
request.

=cut

sub cancel {
    my ( $self, $params ) = @_;
    my $stage = $params->{other}->{stage};
    if ( !$stage || $stage eq 'init' ) {
        # We simply need our template .INC to produce a text block.
        return {
            method  => 'cancel',
            stage   => 'confirm',
            value   => $params,
        };
    } elsif ( $stage eq 'confirm' ) {
        $params->{request}->status("REQREV");
        $params->{request}->orderid(undef);
        $params->{request}->store;
        return {
            method => 'cancel',
            stage  => 'commit',
            next   => 'illview',
            value  => $params,
        };
    } else {
	# Invalid stage, return error.
        return {
            error   => 1,
            status  => 'unknown_stage',
            message => '',
            method  => 'cancel',
            stage   => $params->{stage},
            value   => {},
        };
    }
}

## Helpers

=head3 _validate_borrower

=cut

sub _validate_borrower {
    # Perform cardnumber search.  If no results, perform surname search.
    # Return ( 0, undef ), ( 1, $brw ) or ( n, $brws )
    my ( $input ) = @_;
    my $patrons = Koha::Patrons->new;
    my ( $count, $brw );
    my $query = { cardnumber => $input };

    my $brws = $patrons->search( $query );
    $count = $brws->count;
    my @criteria = qw/ surname firstname end /;
    while ( $count == 0 ) {
        my $criterium = shift @criteria;
        return ( 0, undef ) if ( "end" eq $criterium );
        $brws = $patrons->search( { $criterium => $input } );
        $count = $brws->count;
    }
    if ( $count == 1 ) {
        $brw = $brws->next;
    } else {
        $brw = $brws;           # found multiple results
    }
    return ( $count, $brw );
}

=head1 AUTHOR

Alex Sassmannshausen <alex.sassmannshausen@ptfs-europe.com>

=cut

1;
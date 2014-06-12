package PhaidraPlusBackend::Controller::Userdata;

use strict;
use warnings;
use v5.10;
use Mango::BSON ':bson';
use Mango::BSON::ObjectID;
use Mojo::JSON qw(encode_json);
use base 'Mojolicious::Controller';

sub put_list {
  my $self = shift;

  my $current_user = $self->load_current_user;
  my $username = $current_user->{username};
  my $payload = $self->req->json;

  my $collection = $self->mango->db->collection('lists');

  $collection->insert({username => $username, created => bson_time, updated => bson_time, list => $payload } => sub {
    my ($collection, $err, $oid) = @_;

    return $self->render(json => { alerts => [{ type => 'danger', msg => $err }]}, status => 500) if $err;
    return $self->render(json => { id => $oid }, status => 200);
  });

};

sub get_user_lists {
  my $self = shift;

  my $current_user = $self->load_current_user;
  my $username = $current_user->{username};

  my $collection = $self->mango->db->collection('lists');

  $collection->find({username => $username})->sort({updated => -1})->all(sub {
    my ($collection, $err, $res) = @_;

    return $self->render(json => { alerts => [{ type => 'danger', msg => $err }]}, status => 500) if $err;
    return $self->render(json => { lists => $res }, status => 200);

  });
};

sub get_list {
  my $self = shift;

  my $id = $self->param('id');
  my $current_user = $self->load_current_user;
  my $username = $current_user->{username};

  my $collection = $self->mango->db->collection('lists');

  $collection->find({_id => Mango::BSON::ObjectID->new($id), username => $username})->sort({updated => -1})->all(sub {
    my ($collection, $err, $res) = @_;

    return $self->render(json => { alerts => [{ type => 'danger', msg => $err }]}, status => 500) if $err;
    return $self->render(json => { lists => $res }, status => 200);

  });
};

sub post_list {
  my $self = shift;
  my $id = $self->param('id');
  my $payload = $self->req->json;
  my $current_user = $self->load_current_user;
  my $username = $current_user->{username};

  my $collection = $self->mango->db->collection('lists');

  $collection->update({_id => Mango::BSON::ObjectID->new($id), username => $username},{ '$set' => {updated => bson_time, list => $payload} } => sub {
    my ($collection, $err, $oid) = @_;

    return $self->render(json => { alerts => [{ type => 'danger', msg => $err }]}, status => 500) if $err;
    return $self->render(json => { id => $oid }, status => 200);
  });

};

sub delete_list {
  my $self = shift;
  my $id = $self->param('id');
  my $current_user = $self->load_current_user;
  my $username = $current_user->{username};

  my $collection = $self->mango->db->collection('lists');

  $collection->remove({_id => Mango::BSON::ObjectID->new($id), username => $username} => sub {
    my ($collection, $err, $oid) = @_;

    return $self->render(json => { alerts => [{ type => 'danger', msg => $err }]}, status => 500) if $err;
    return $self->render(json => {}, status => 200);
  });

};

1;

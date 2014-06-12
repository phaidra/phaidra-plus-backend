package PhaidraPlusBackend::Controller::Authentication;

use strict;
use warnings;
use v5.10;
use Mojo::ByteStream qw(b);
use Mojo::JSON qw(encode_json);
use base 'Mojolicious::Controller';

# bridge
sub check {	
	my $self = shift;
	
	$self->app->log->debug("checking...");
	
	my $current_user = $self->load_current_user;
	
	unless($current_user->{username}){
		$self->app->log->debug("not authenticated...");
		$self->res->headers->www_authenticate('Basic "'.$self->app->config->{authentication}->{realm}.'"');
    	$self->render(json => { alerts => [{ type => 'danger', msg => 'please authenticate' }]} , status => 401) ;
    	return;
	}

	my $init_data = { current_user => $current_user };
	
	$self->app->log->debug("authenticated...\n".$self->app->dumper($init_data));
	
    $self->stash(init_data => encode_json($init_data));   
    return 1;    
}

sub keepalive {
	my $self = shift;
	my $session = $self->stash('mojox-session');
	$session->load;
	if($session->sid){
		$self->render(json => { expires => $session->expires } , status => 200 ) ;
	}else{		
		$self->render(json => { alerts => [{ type => 'danger', msg => 'session not found' }] } , status => 401 ) ;		
	}		
}

sub signin {
	
	my $self = shift;
		
	my $auth_header = $self->req->headers->authorization;
    # this should not happen, we are using this login method only on frontend
    # where we generate the request ourselves
    unless($auth_header)
    {
    	$self->res->headers->www_authenticate('Basic "'.$self->app->config->{authentication}->{realm}.'"');
    	$self->render(json => { alerts => [{ type => 'danger', msg => 'please authenticate' }]} , status => 401) ;
    	return;
    }
    
    my ($method, $str) = split(/ /,$auth_header);
    my ($username, $password) = split(/:/, b($str)->b64_decode);
    
    $self->app->log->info("Authenticating user: ".$username);
    my $res = $self->authenticate($username, $password);    
    
    if($res->{status} eq 200){
    
	    # create sessoin
	   	my $session = $self->stash('mojox-session');
		$session->load;
		unless($session->sid){		
			$session->create;		
		}	
		
		# save api token
		$session->data(phaidra_api_token => $res->{phaidra_api_token});
						
		# get & save login data		
		my $ld = $self->directory->get_login_data($self, $username);										
		$session->data(current_user => $ld);			
		$self->app->log->info("Loaded user: ".$self->app->dumper($session->data('current_user')));				  		
	    
	    # sent token cookie	
		my $cookie = Mojo::Cookie::Response->new;
	    $cookie->name($self->app->config->{authentication}->{token_cookie})->value($session->sid);
	    $cookie->secure(1);
	    $self->tx->res->cookies($cookie);
    
    	$self->render(json => { alerts => $res->{alerts}, $self->app->config->{authentication}->{token_cookie} => $session->sid} , status => $res->{status});
    	return;
    }    
    
    $self->render(json => { alerts => $res->{alerts}} , status => $res->{status});
}

sub authenticate {
	my ($self, $username, $password, $extradata) = @_;
		
			my $url = Mojo::URL->new;
			$url->scheme('https');		
			$url->userinfo($username.":".$password);
			my @base = split('/',$self->app->config->{phaidra}->{apibaseurl});
			$url->host($base[0]);
			$url->path($base[1]."/signin") if exists($base[1]);	
		  	my $tx = $self->ua->get($url); 
		
		 	if (my $res = $tx->success) {		
					$self->app->log->info("User $username successfuly authenticated");
			  		
			  		my $phaidra_api_token = $tx->res->cookie($self->app->config->{authentication}->{token_cookie})->value;	
  		
			  		my %ret = ( phaidra_api_token => $phaidra_api_token , alerts => $tx->res->json->{alerts}, status  =>  200 );			  		
			  		return \%ret;
			 }else {
				 	my ($err, $code) = $tx->error;
				 	$self->app->log->info("Authentication failed for user $username. Error code: $code, Error: $err");
				 	my %ret;
				 	if($tx->res->json && exists($tx->res->json->{alerts})){	  
						%ret = ( alerts => $tx->res->json->{alerts}, status  =>  $code ? $code : 500 );						 	
				 	}else{
						%ret = ( alerts => [{ type => 'danger', msg => $err }], status  =>  $code ? $code : 500 );
					}
				 				  		
			  		return \%ret;
				 	
			}				
			
			
}

sub signout {
	my $self = shift;
	
	my $url = Mojo::URL->new;
	$url->scheme('https');		
	my @base = split('/',$self->app->config->{phaidra}->{apibaseurl});
	$url->host($base[0]);
	if(exists($base[1])){
		$url->path($base[1]."/signout") ;
	}else{
		$url->path("/signout") ;
	}
			
	my $token = $self->load_phaidra_api_token;
	my $current_user = $self->load_current_user;
	
	$self->app->log->debug("Deleting session");	
	my $session = $self->stash('mojox-session');	
	$session->load;
	$session->expire;							
	$session->flush;
				
	my $tx = $self->ua->get($url => {$self->app->config->{authentication}->{token_header} => $token}); 
	
	if (my $res = $tx->success) {		
				
		$self->app->log->info("User ".$current_user->{username}." successfuly signed out");
		$self->render(json => { alerts => [{ type => 'success', msg => "You have been signed out" }]}, stauts  =>  200 );
	}else {
		my ($err, $code) = $tx->error;
			 	
		$self->app->log->info("Sign out failed for user ".$current_user->{username}." error: $code:$err");
				
	 	if($tx->res->json){	  
		  	if(exists($tx->res->json->{alerts})) {
		  		$self->app->log->error($self->app->dumper($tx->res->json->{alerts}));
		  		$self->render(json => { alerts => $tx->res->json->{alerts}}, stauts  =>  $code ? $code : 500 );						 	
			}else{
				$self->app->log->error($err);
			 	$self->render(json =>  { alerts => [{ type => 'danger', msg => $err }]}, stauts  =>  $code ? $code : 500);						  	
			}
		}		
	}

}


1;

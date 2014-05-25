package PhaidraPlusBackend;

use strict;
use warnings;
use Mojo::Base 'Mojolicious';
use Mojo::Log;
use Mojolicious::Plugin::I18N;
use Mojolicious::Plugin::Authentication;
use Mojolicious::Plugin::Session;
use Mojo::Loader;
use lib "lib/phaidra_directory";
use lib "lib/phaidra_binding";
use PhaidraPlusBackend::Model::Session::Store::Mongo;

# This method will run once at server start
sub startup {
    my $self = shift;

    my $config = $self->plugin( 'JSONConfig' => { file => 'PhaidraPlusBackend.json' } );
	$self->config($config);  
	$self->mode($config->{mode});     
    $self->secrets([$config->{secret}]);
    
    # init log	
  	$self->log(Mojo::Log->new(path => $config->{log_path}, level => $config->{log_level}));

	my $directory_impl = $config->{directory_class};
	my $e = Mojo::Loader->new->load($directory_impl);    
    my $directory = $directory_impl->new($self, $config);
 
    $self->helper( directory => sub { return $directory; } );
    
    # init auth
    $self->plugin(authentication => {
		load_user => sub {
			my $self = shift;
			my $username  = shift;
			$self->app->log->info("Loading user: ".$username);
			return $self->directory->get_login_data($self, $username);
		},
		validate_user => sub {
			my ($self, $username, $password, $extradata) = @_;
			$self->app->log->info("Validating user: ".$username);
			
			my $url = Mojo::URL->new;
			$url->scheme('https');		
			$url->userinfo($username.":".$password);
			my @base = split('/',$self->app->config->{phaidra}->{apibaseurl});
			$url->host($base[0]);
			$url->path($base[1]."/signin") if exists($base[1]);	
		  	my $tx = $self->ua->get($url); 
		
		 	if (my $res = $tx->success) {
			  		
			  		# save token
			  		my $token = $tx->res->cookie($self->app->config->{authentication}->{token_cookie})->value;	
  		
			  		my $session = $self->stash('mojox-session');
					$session->load;
					unless($session->sid){		
						$session->create;		
					}	
					$self->save_token($token);
			  		
			  		$self->app->log->info("User $username successfuly authenticated");
			  		$self->stash({phaidra_auth_result => { token => $token , alerts => $tx->res->json->{alerts}, status  =>  200 }});
			  		
			  		return $username;
			 }else {
				 	my ($err, $code) = $tx->error;
				 	$self->app->log->info("Authentication failed for user $username. Error code: $code, Error: $err");
				 	if($tx->res->json && exists($tx->res->json->{alerts})){	  
						$self->stash({phaidra_auth_result => { alerts => $tx->res->json->{alerts}, status  =>  $code ? $code : 500 }});						 	
				 	}else{
						$self->stash({phaidra_auth_result => { alerts => [{ type => 'danger', msg => $err }], status  =>  $code ? $code : 500 }});
					}
				 	
				 	return undef;
			}				
			
		},
	});
	
	$self->helper(mango => sub { state $mango = Mango->new('mongodb://'.$config->{mongodb}->{username}.':'.$config->{mongodb}->{password}.'@'.$config->{mongodb}->{host}.'/'.$config->{mongodb}->{database}) });
	
    # we might possibly save a lot of data to session 
    # so we are not going to use cookies, but a database instead
    $self->plugin(
        session => {
            stash_key     => 'mojox-session',
	    	store  => PhaidraPlusBackend::Model::Session::Store::Mongo->new( 
	    		mango => $self->mango, 
	    		'log' => $self->log 
	    	),              
	    	transport => MojoX::Session::Transport::Cookie->new(name => 'b_'.$config->{installation_id}),
            expires_delta => $config->{session_expiration}, 
	    	ip_match      => 1
        }
    );
       
	$self->hook('before_dispatch' => sub {
		my $self = shift;		  
		
		my $session = $self->stash('mojox-session');
		$session->load;
		if($session->sid){
			# we need mojox-session only for signed-in users
			if($self->signature_exists){
				$session->extend_expires;
				$session->flush;
			}else{
				# this will set expire on cookie as well as in store
				$session->expire;							
	      		$session->flush;	
			}
		}else{
			if($self->signature_exists){
				$session->create;
			}
		}
      	
	});
	    
	$self->sessions->default_expiration($config->{session_expiration});
	# 0 if the ui is not running on https, otherwise the cookies won't be sent and session won't work
	$self->sessions->secure($config->{secure_cookies}); 
	$self->sessions->cookie_name('a_'.$config->{installation_id});
                      
    $self->helper(save_token => sub {
    	my $self = shift;
		my $token = shift;
		
		my $session = $self->stash('mojox-session');
		$session->load;
		unless($session->sid){		
			$session->create;		
		}	
		
		$session->data(token => $token);
    });
    
    $self->helper(load_token => sub {
    	my $self = shift;
    	
    	my $session = $self->stash('mojox-session');
		$session->load;
		unless($session->sid){
			return undef;
		}
		
		return $session->data('token');		
    });	 
           
  	# init I18N
  	$self->plugin(charset => {charset => 'utf8'});
  	$self->plugin(I18N => {namespace => 'PhaidraPlusBackend::I18N', support_url_langs => [qw(en de it sr)]});
  	
  	# init cache
  	$self->plugin(CHI => {
	    default => {
	      	driver		=> 'Memory',
	      	#driver     => 'File', # FastMmap seems to have problems saving the metadata structure (it won't save anything)
	    	#root_dir   => '/tmp/phaidra-ui-cache',
	    	#cache_size => '20m',
	      	global => 1,
	      	#serializer => 'Storable',
	    },
  	});
    
    # if we are proxied from base_apache/ui eg like
    # ProxyPass /ui http://localhost:3000/
    # then we have to add /ui/ to base of every req url
    # (set $config->{proxy_path} in config)
    if($config->{proxy_path}){
	    $self->hook('before_dispatch' => sub {
		my $self = shift;		    
	      	push @{$self->req->url->base->path->trailing_slash(1)}, $config->{proxy_path};
	    });
    }

    my $r = $self->routes;
    $r->namespaces(['PhaidraPlusBackend::Controller']);
    
    $r->route('') 			  		->via('get')   ->to('frontend#home');
    $r->route('signin') 			  	->via('get')   ->to('authentication#signin');
    $r->route('signout') 			->via('get')   ->to('authentication#signout');
      
    $r->route('proxy/get_uwmetadata_tree') ->via('get')   ->to('proxy#get_uwmetadata_tree');
    $r->route('proxy/get_uwmetadata_languages') ->via('get')   ->to('proxy#get_uwmetadata_languages');
    $r->route('proxy/get_help_tooltip') ->via('get')   ->to('proxy#get_help_tooltip');
    $r->route('proxy/get_directory_get_org_units') ->via('get')   ->to('proxy#get_directory_get_org_units');
    $r->route('proxy/get_directory_get_study') ->via('get')   ->to('proxy#get_directory_get_study');
    $r->route('proxy/get_directory_get_study_name') ->via('get')   ->to('proxy#get_directory_get_study_name');        
    $r->route('proxy/objects') ->via('get')   ->to('proxy#search_owner');
    $r->route('proxy/objects/:username') ->via('get')   ->to('proxy#search_owner');
    $r->route('proxy/search') ->via('get')   ->to('proxy#search');
    $r->route('proxy/object/:pid/related') ->via('get')   ->to('proxy#get_related_objects');
    
    # if not authenticated, users will be redirected to login page
    my $auth = $r->bridge->to('authentication#check');
    
    $auth->route('/ls/')	->via('put')	->to('userdata#put_list');
    $auth->route('/ls/')	->via('get')	->to('userdata#get_user_lists');    
    $auth->route('/ls/:id/')->via('get')	->to('userdata#get_list');    
    $auth->route('/ls/:id/')->via('post')	->to('userdata#post_list');
    $auth->route('/ls/:id/')->via('del')	->to('userdata#delete_list');
    
    $auth->route('proxy/get_object_uwmetadata/:pid') ->via('get')   ->to('proxy#get_object_uwmetadata');
    $auth->route('proxy/save_object_uwmetadata/:pid') ->via('post')   ->to('proxy#save_object_uwmetadata');    
    $auth->route('proxy/collection/create') ->via('post')   ->to('proxy#collection_create');
    $auth->route('proxy/collection/:pid/members/order') ->via('post')   ->to('proxy#collection_order');
    $auth->route('proxy/collection/:pid/members/:itempid/order/:position') ->via('post')   ->to('proxy#collection_member_order');
    $auth->route('proxy/collection/:pid/members/:itempid/order/') ->via('post')   ->to('proxy#collection_member_order');
    
    return $self;
}

1;

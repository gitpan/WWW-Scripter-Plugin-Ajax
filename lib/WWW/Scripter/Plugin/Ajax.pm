package WWW::Scripter::Plugin::Ajax;

use 5.006;

use HTML::DOM::Interface ':all';
use Scalar::Util 'weaken';

use warnings; no warnings 'utf8';

our $VERSION = '0.04';

sub init {
	my($pack,$mech) = (shift,shift);
	my $js_plugin = $mech->use_plugin(JavaScript => @{$_[0]});
	@{$_[0]} = ();
	
	$js_plugin->bind_classes({
		__PACKAGE__.'::XMLHttpRequest' => 'XMLHttpRequest',
		XMLHttpRequest => {
			_constructor => sub {
				(__PACKAGE__."::XMLHttpRequest")->new(
					$mech, @_)
			},
			# ~~~ I need to verify these return types.
			abort => METHOD | VOID,
			getAllResponseHeaders => METHOD | STR,
			getResponseHeader => METHOD | STR,
			open => METHOD | VOID,
			send => METHOD | VOID,
			setRequestHeader => METHOD | VOID,

			onreadystatechange => OBJ,
			readyState => NUM | READONLY,
			responseText => STR | READONLY,
			responseXML => OBJ | READONLY,
			status => NUM | READONLY,
			statusText => STR | READONLY,

			addEventListener => METHOD | VOID,
			removeEventListener => METHOD | VOID,
			dispatchEvent => METHOD | BOOL,

			_constants => [
				map __PACKAGE__."::XMLHttpRequest::$_",qw[
					UNSENT OPENED HEADERS_RECEIVED
					LOADING DONE
			]],
		},
	});

	weaken $mech; no warnings 'parenthesis';
	return bless \my $foo, $pack;
	# That $foo thing is used below to store one tiny bit of info:
	# whether bind_class has been called yet. (I’ll have to change the
	# structure if we need to store anything else.)
}

sub options {
	${+shift}->plugin('JavaScript')->options(@_);
}

package WWW::Scripter::Plugin::Ajax::XMLHttpRequest;

use Encode 2.09 'decode';
use Scalar::Util 1.09 qw 'weaken blessed refaddr';
use HTML::DOM::Event;
use HTML::DOM::Exception qw 'SYNTAX_ERR NOT_SUPPORTED_ERR
                             INVALID_STATE_ERR';
use HTTP::Headers;
use HTTP::Headers::Util 'split_header_words';
use HTTP::Request;
no  LWP::Protocol();
use URI 1;
use URI::Escape;

use constant 1.03 do { my $x; +{
	map(+($_=>$x++), qw[ UNSENT OPENED HEADERS_RECEIVED LOADING DONE]),
	SECURITY_ERR => 18,
	NETWORK_ERR => 19,
	ABORT_ERR => 20,
}};

# There are six different states that the object can be in:
#   UNSENT           - actually means uninitialised
#   OPENED           - i.e., initialised
#   SENT             - what it says
#   HEADERS_RECEIVED - what it says
#   LOADING          - body is downloading
#   DONE             - zackly what it says
# Five of them are represented by the constants above, and
# are returned  by  the  readyState  method.  The  opened  and
# sent states are conflated and  represented  by  the  OPENED  con-
# stant in the badly-designed (if designed at all)  public  API.  The
# SENT constant is used only internally,  which is why it is one of the
# lexical constants below.  We need to make this distinction,  since cer-
# tain methods are supposed to  die  in  the  SENT  state,  but  not  the
# OPENED  state.  Furthermore,  we  *do*  trigger  orsc  when  the  state
# changes to SENT.
# ~~~ Actually, we don’t do that yet because all the tuits I’ve been
#     receiving lately were square, rather than round.

# The lc lexical constants are field indices.

use constant::lexical {
	SENT => 1.5,
	mech => 0,
	clone => 1,
	method => 2,
	url => 3,
	async => 4,
	name => 5,
	pw => 6,
	orsc => 7,
	state => 8,
	res => 9,
	headers => 10,
	tree => 11,
	xml => 12, # boolean
};

sub new {
	my $self = bless [], shift;
	$self->[mech] = shift;
	weaken $self->[mech];
	$self->[state] = 0;
	$self;
}


# Instance Methods

my $http_token = '[^]\0-\x1f\x7f()<>\@,;:\\\"/[?={} \t]+';
my $http_field_val = '[^\0-\ch\ck\cl\cn-\x1f]*';

sub open{
	my ($self) = shift;
	@$self[method,url,async] = @_;
	@_ < 3 and $self->[async] = 1; # default
	shift,shift,shift;

	for($self->[method]) {
		/^$http_token\z/o
			or die new HTML::DOM::Exception SYNTAX_ERR,
				"Invalid HTTP method: $self->[method]";
		/^(?:connect|trac[ek])\z/i
			and die new HTML::DOM::Exception SECURITY_ERR,
				"Use of the $_ method is forbidden";
		s/^(?:delete|head|options|(?:ge|p(?:os|u))t)\z/uc/ie;
	}	

	$self->[url] = my $url = new_abs URI $self->[url],
			$self->[mech]->base;
	_check_url($url, $self->[mech]->uri);
	$url->fragment(undef); # ~~~ Shouldn’t WWW::Scripter be doing this

	if(@_){ # name arg
		if( defined($self->[name] = shift) ) {
			if(@_) {
				$self->[pw] = shift;
			}
			elsif($url->can('userinfo')
			      and defined(my $ui = $url->userinfo)) {
				$ui =~ /:(.*)/s and
					$self->[pw] = uri_unescape($1)
			}
		}
	}
	elsif($url->can('userinfo') and defined(my$ ui = $url->userinfo)) {
		($self->[name],my $pw) = map uri_unescape($_),
                                          split(":", $ui, 2);
		$self->[pw] = $pw if defined $pw; # avoid clobbering it
		                                  # when we shouldn’t
	}

	delete @$self[res,headers];
	$self->[state]=1;
	$self->_trigger_orsc;
	return;
}

sub _check_url { # checks protocol and same-originness
	my ($new,$current,$error_code) = @_;
	length LWP'Protocol'implementor $new->scheme
		or die new HTML::DOM::Exception
		 $error_code||NOT_SUPPORTED_ERR,
		 "Protocol scheme '${\$new->scheme}' is not supported";

	my $host1 = eval{$current->host};
	my $host2 = eval{$new->host};
	!defined $host1 || !defined $host2 || $host1 ne $host2
		and die new HTML'DOM'Exception $error_code||SECURITY_ERR,
			"Permission denied ($new: wrong host)";
	$current->scheme ne $new->scheme
		and die new HTML'DOM'Exception $error_code||SECURITY_ERR,
			"Permission denied ($new: wrong scheme)";
	no warnings 'uninitialized';
	eval{$current->port}ne eval{$new->port}
		and die new HTML'DOM'Exception $error_code||SECURITY_ERR,
			"Permission denied ($new: wrong port)";
}

sub send{
	die new HTML::DOM::Exception INVALID_STATE_ERR,
	    "send can only be called once between calls to open"
	  unless $_[0][state] == OPENED;

	my ($self, $data) = @_;
	my $clone = $self->[clone] ||=
		bless $self->[mech]->clone, 'LWP::UserAgent';
		# ~~~ This doesn’t allow for Scripter subclasses that
		#     cache, etc. What’s the best way to circumvent
		#     Scripter’s DOM parsing, Mech’s global credentials,
		#     etc.?
#	$clone->stack_depth(1);
#	$clone->plugin('DOM')->scripts_enabled(0);
	my $headers = new HTTP::Headers @{$self->[headers]||[]};
	defined $self->[name] || defined $self->[pw] and
		$headers->authorization_basic($self->[name], $self->[pw]);
	no warnings 'uninitialized';
	my $request = new HTTP::Request $self->[method], $self->[url],
		$headers,
		$self->[method] =~ /^(?:get|head)\z/i ? () : "$data";
	my $jar = $clone->cookie_jar;
	my $jar_class; # no, this has nothing to do with Java
	$jar and $jar_class = ref $jar,
	         bless $jar, 'WWW::Scripter::Plugin::Ajax::Cookies';

	# The spec says to set the send() flag only if it’s an asynchronous
	# request. I think that is a mistake, because the following would
	# cause infinite recursion otherwise:
	#  with( new XMLHttpRequest ) {
	#    open ('GET', 'foo', false) //synchronous
	#    onreadystatechange = function() {
	#      if(readyState == XMLHttpRequest.OPENED) send()
	#    }
	#    send()
	#  }
	$self->[state] = SENT;
	$self->_trigger_orsc;

	$self->[state] = HEADERS_RECEIVED; # ~~~ This is in the wrong place
	$self->_trigger_orsc;              # When I fix this, I need to
	                                   # make sure the redirect_ok
	                                   # hook is not present during
	                                   # orsc, since it would affect
	                                   # other requests

	# Insert hook to check redirections
	my $error; my $redirected; my $res;
	{
		no warnings 'redefine';
		local *LWP'UserAgent'redirect_ok = sub {
			local $@;
			eval{
				_check_url(
				  $_[1]->url,
				  $self->[mech]->uri,
				  NETWORK_ERR,
				)
			};
			++$redirected;
			not $error=$@
		};

	# send request
		$res = $self->[res] = $clone->request($request);
	}

	# check for bad redirects
	my $async = $self->[async];
	if(
	 $error
	  or
	 # (check $redirected first to avoid a method call)
	 $redirected and $res->code =~ /^3/ and
	  (
	   $async || (
	    $error = new HTML'DOM'Exception NETWORK_ERR,
	     "Infinite redirect"
	   ),
	   1
	  )
	) {
		$self->[state] = 4;
		delete $self->[res];
		$async ? ($self->_trigger_orsc, return) : die $error;
	}

	$self->[state] = LOADING;
	$self->_trigger_orsc;

	$jar and bless $jar, $jar_class;

	$self->[xml] = ($res->content_type||'') =~
	   /(?:^(?:application|text)\/xml|\+xml)\z/ || undef;
	# This needs to be undef, rather than false, for responseXML to
	# work correctly.

	$self->[state] = 4; # complete
	$self->_trigger_orsc;
	delete $self->[tree] ;

	return $res->is_success;
	# ~~~ Ajax for Web Application Developers says it has to equal 200.
	#     That doesn’t sound right to me. (E.g., what if it’s 206?)
}

sub abort { # ~~~ If I make this asynchronous, this method might actually
            #     be made to do something useful.
	shift->[state] = 0;
	return
}

sub getAllResponseHeaders { # ~~~ is the format correct?
	no warnings 'uninitialized';
	$_[0][state] <= OPENED
	 and die new HTML'DOM'Exception INVALID_STATE_ERR,
	  "getAllResponseHeaders only works after calls to send()";
	(shift->[res]||return '')->headers->as_string
}

sub getResponseHeader {
	no warnings 'uninitialized';
	$_[0][state] <= OPENED
	 and die new HTML'DOM'Exception INVALID_STATE_ERR,
	  "getResponseHeader only works after calls to send()";
	(shift->[res]||return)->header(shift)
}

sub setRequestHeader {
	die new HTML::DOM::Exception INVALID_STATE_ERR,
	    "setRequestHeader can only be called between open and send"
	  unless $_[0][state] == OPENED;
	$_[1] =~ /^$http_token\z/o
		or die new HTML::DOM::Exception SYNTAX_ERR,
			"Invalid HTTP header name: $_[1]";
	defined $_[2] or return;
	$_[2] =~ /^$http_field_val\z/o
		or die new HTML::DOM::Exception SYNTAX_ERR,
			"Invalid HTTP header value: $_[2]";

	# This regexp does not include all those in the 4th  of  Sep.
	# Editor’s Draft of the spec. Anyway the spec only says ‘SHOULD’,
	# so we are still compliant in this regard.  I have  very  specific
	# reasons for letting these through:
	#   Accept-Charset  There is no reason the user agent  should  have
	#                   to support charsets requested by a script.  The
	#                   script itself can decode the charset (once I’ve
	#                   implemented overrideMimeType or  responseData).
	#   Authorization   If the user agent does not support an authenti-
	#                   cation method, this should not prevent a script
	#                   from using it.
	#   Cookie(2)       Fake cookies are known enough to be documented
	#                   in some books on Ajax/JS; e.g., the Rhino.
	#   User-Agent      Some server-side scripts might want to distin-
	#                   guish between actual user requests and script-
	#                   based requests. After all, the scripts will be
	#                   originating from the same server, so it’s not a
	#                   matter of security.
	return if $_[1] =~ /^(?:
		(?:
			accept-encoding
			  |
			con(?:nection|tent-(?:length|transfer-encoding))
			  |
			(?:dat|keep-aliv|upgrad)e
			  |
			(?:expec|hos)t
			  |
			referer
			  |
			t(?:e|ra(?:iler|nsfer-encoding))
			  |
			via
			  |
		)\z
		  |
		(?:proxy|sec)-
	)/xi;

	push@{shift->[headers] ||= []}, ''.shift, ''.shift;
		# We have to stringify to avoid making LWP hiccough.
}


# Attributes

sub onreadystatechange {
	my $old = $_[0]->[orsc]{attr};
	defined $_[1]
		? $_[0]->[orsc]{attr} = $_[1]
		: delete $_[0]->[orsc]{attr}
	  if @_ > 1;
	$old;
}

sub readyState {
	int shift->[state];
}

sub responseText { # string response from the server
	my $content = (my $res = $_[0]->[res]||return '')->content;
	my $cs = { map @$_,
	  split_header_words $res->header('Content-Type')
	 }->{charset};
	decode defined $cs ? $cs : utf8 => $content
}

sub responseXML { # XML::DOM::Lite object
	my $self = shift;
	$$self[state] == 4 or return;
	$$self[tree] || $$self[xml] && do {
		require WWW::Scripter::Plugin::Ajax::_xml_stuff;
		$$self[mech]->plugin('JavaScript')->bind_classes(
			\%WWW::Scripter::Plugin::Ajax::_xml_interf
		) unless ${$$self[mech]->plugin('Ajax')}++;
		$self->[tree] =
		    XML::DOM::Lite::Parser->parse($$self[res]->content);
		# ~~~ xdlp returns an empty document when there is a parse
		#     error. Could I detect that and return nothing? Or can
		#     a valid XML document be empty?
	}
}

sub status { # HTTP status code
	die "The HTTP status code is not available yet"
		if $_[0][state] < 3;
	shift->[res]->code
}

sub statusText { # HTTP status massage
	die "The HTTP status message is not available yet"
		if $_[0][state] < 3;
	shift->[res]->message
}


# EventTarget Methods

sub _trigger_orsc {
	(my $event = (my $self = shift)->[mech]->document
		->createEvent
	 )->initEvent('readystatechange'); # 2nd and 3rg args false
	$self->dispatchEvent($event);
	return;
}

sub addEventListener {
	my ($self,$name,$listener, $capture) = @_;
	return if $capture;
	return unless $name =~ /^readystatechange\z/i;
	$$self[orsc]{refaddr $listener} = $listener;
	return;
}

sub removeEventListener {
	my ($self,$name,$listener, $capture) = @_;
	return if $capture;
	return unless $name =~ /^readystatechange\z/i;
	exists $$self[orsc] &&
		delete $$self[orsc]{refaddr $listener};
	return;
}

# ~~~ What about a ‘this’ value?
sub dispatchEvent { # This is where all the work is.
	my ($target, $event) = @_;
	my $name = $event->type;
	return unless $name =~ /^readystatechange\z/i;

	my $eh = $target->[mech]->document->error_handler;

	$event->_set_target($target);
	$event->_set_eventPhase(HTML::DOM::Event::AT_TARGET);
	$event->_set_currentTarget($target);
	{eval {
		defined blessed $_ && $_->can('handleEvent') ?
			$_->handleEvent($event) : &$_($event);
		1
	} or $eh and &$eh() for values %{$target->[orsc]||last};}
	return !cancelled $event;
}



package WWW::Scripter::Plugin::Ajax::Cookies;
require HTTP::Cookies;
@ISA = HTTP::Cookies;

# We have to override this to make sure that add_cookie_header doesn’t
# clobber any fake cookies.

sub add_cookie_header {
	my $self = shift;
	my($request)= @_ or return;
	my @cookies = $request->header('Cookie');
	my @ret = $self->SUPER::add_cookie_header(@_);
	@ret and @cookies and
	   join ', ', @cookies, ne $request->header('Cookie')
	  and $request->push_header(cookie => \@cookies);
	wantarray ? @ret : $ret[0];
}

!+()

__END__

How exactly should the control flow work if the
connection is supposed to be asynchronous? If threads are supported, I
could make the connection in another thread, and have some message passed
back. In the absence of threads, I could use forking and signals, or use
that regardless of thread support; but it might not be portable. In any
case, the client script (in the main thread) will have to tell the
XMLHttpRequest object to check whether it's ready yet (from some event
loop, presumably), and, if it is, the
latter will call its readystatechange event. This could be hooked into the
wmpjs's timeout system. Or do we need another API for it?

Perhaps the current synchronous behaviour should be
the default even with a threaded Perl, and the threaded behaviour should be
optional.

=head1 NAME

WWW::Scripter::Plugin::Ajax - WWW::Scripter plugin that provides the XMLHttpRequest object

=head1 VERSION

Version 0.04 (alpha)

=head1 SYNOPSIS

  use WWW::Scripter;
  $w = new WWW::Scripter;
  
  $m->use_plugin('Ajax');
  $m->get('http://some.site.com/that/relies/on/ajax');

=head1 DESCRIPTION

This module is a plugin for L<WWW::Scripter> that loads the JavaScript
plugin (L<WWW::Scripter::Plugin::JavaScript>) and provides it with the
C<XMLHttpRequest> object.

To load the plugin, use L<WWW::Scripter>'s C<use_plugin> method, as shown
in the Synopsis. Any extra arguments to C<use_plugin> will be passed on to 
the
JavaScript plugin (at least for now).

=head1 ASYNCHRONY

The C<XMLHttpRequest> object currently does not support asynchronous
connections. Later this will probably become an option, at least for
threaded perls.

=head1 NON-HTTP ADDRESSES

Since it uses L<LWP>, URI schemes other than http (e.g., file, ftp) are
supported.

=head1 INTERFACE

The XMLHttpRequest interface members supported so far are:

  Methods:
  open
  send
  abort
  getAllResponseHeaders
  getResponseHeader
  setRequestHeader
  
  Attributes:
  onreadystatechange
  readyState
  responseText
  responseXML
  status
  statusText
  
  Event-Related Methods:
  addEventListener
  removeEventListener
  dispatchEvent

  Constants (static properties):
  UNSENT
  OPENED
  HEADERS_RECEIVED
  LOADING
  DONE

C<responseBody>, C<overrideMimeType>, C<getRequestHeader>, 
C<removeRequestHeader> and more event attributes are likely to be added in
future versions.

=head1 PREREQUISITES

This plugin requires perl 5.8.3 or higher, and the following modules:

=over 4

=item *

WWW::Scripter::Plugin::JavaScript version 0.002 or
later

=item *

constant::lexical

=item *

XML::DOM::Lite

=item *

HTML::DOM version 0.013 or later

=item *

Encode 2.09 or higher

=item *

WWW::Scripter

=item *

LWP

=item *

URI

=back

=head1 BUGS

If you find any bugs, please report them to the author by e-mail
(preferably with a
patch :-).

XML::DOM::Lite is quite lenient toward badly-formed XML, so the 
C<responseXML> property returns something useful even in cases when it
should be null.

The C<send> method does not yet accept a Document object as its argument.
(Well, it does, but it stringifies it to '[object Document]' instead of
serialising it as XML.)

The SECURITY_ERR, NETWORK_ERR and ABORT_ERR constants are not available
yet, as I don't know where to put them.

It does not conform to the spec in every detail, since the spec is still
being written and is different every time I check it.

None of the additional features in the Level 2 spec are implemented.

There is currently no API to signal that the user has cancelled a
connection. You can call the C<abort> method, but that does not have
exactly the same result that a user-initiated cancellation is meant to 
have.

Furthermore, this module follows the badly-designed API that is
unfortunately the standard so I can't do anything about it.

=head1 AUTHOR & COPYRIGHT

Copyright (C) 2008-9 Father Chrysostomos
<C<< ['sprout', ['org', 'cpan'].reverse().join('.')].join('@') >>E<gt>

This program is free software; you may redistribute it and/or modify
it under the same terms as perl.

=head1 SEE ALSO

L<WWW::Scripter>

L<WWW::Scripter::Plugin::JavaScript>

L<XML::DOM::Lite>

The C<XMLHttpRequest> specification (draft as of August 2009):
L<http://www.w3.org/TR/XMLHttpRequest/>

C<XMLHttpRequest> Level 2: L<http://www.w3.org/TR/XMLHttpRequest2/>

L<WWW::Mechanize::Plugin::Ajax> (the original version of this module)

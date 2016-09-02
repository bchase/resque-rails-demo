# Resque Rails Demo

## The Problem

There's not just one problem that Resque can solve, but this is the problem I've used it for the most: the computation of a controller action takes longer than is possible, or reasonable.

What does this mean?

First, let's talk about the "possible" case.

### Longer than possible (on e.g. Heroku)

From [the Heroku docs](https://devcenter.heroku.com/articles/deploying-rails-applications-with-the-puma-web-server#timeout):

> There is no request timeout mechanism inside of Puma [the default web server for Rails 5]. The Heroku router will timeout all requests that exceed 30 seconds.

This is bad, not only because the client will fail to receive a proper response, but also...

> Although an error will be returned back to the client, Puma will continue to work on the request as there is no way for the router to notify Puma that the request terminated early.

They go on to recommend using `Rack::Timeout` to solve this problem of Puma continuing to run and waste resources for naught, but we still need to figure out how to go about finishing our lengthy computation, and then getting the result to the client. The first part of this (finishing the computation) is where Resque comes in.

But before we get to that, let's talk about unreasonable requests.

### Longer than reasonable requests

Now, even though the default timeout for requests on Heroku is 30 seconds, that's way, way, waaaay too long to let a web worker take for a single request. The time it "should" take is debatable (and likely varies, depending on what you're doing), but ideally our requests should be measurable in, say, hundreds of *milliseconds* on the high end, *not* in seconds in the double digits.

The reason for this is that you have only a finite number of web workers running at a given time, and they can only handle a finite number of requets. If one of them hangs for a full 30 seconds, you get a disasterous scenario where requests pile up, and there aren't enough web workers to handle them all at once, much like finding yourself waiting in a line of a dozen people for the single grocery store clerk to ring everyone up.

Thus, we *do* want requests to time out (and *way* sooner than 30 seconds, in case I haven't run that into the ground yet), but sometimes we have tasks that take longer than a few hundred milliseconds. So what do we do?

## An Example

For my startup, we recently ran into this problem with exports on Heroku. As the size of our customers' datasets grew, their exports would take longer, and this eventually put the exporting process well past the timeout limit.

As I said before, the actually computation here can be offloaded to Resque, but I still haven't addressed how to deal with getting the results to the client once the computation is complete.

First, let's look at what our flow looks like so fare. Assuming we offload the work to Resque (which I'll talk more about in a minute), here's what the new process looks like, in the case of dealing with our lengthy exporting process:

1. client - user visits the exports page and clicks a link to request a new export of their data be created
2. server - the request hits the server and gets routed to `exports#create`
3. server - `exports#create` queues the exporting up with Resque (more on this later)
4. server - `exports#create` responds with a `2XX` and a message to let the client know the request was a success and that the export is being created
5. client - the user sees a `Your export is being created, please wait.` message

Completely asynchronous to the above request/response cycle, the Resque worker will be watching the queue, notice the new job, pop it off the queue, and create the export as requested.

But the problem left to solve is this: how do we show the export to the user?

There are probably a number of ways to approach this, but I chose to:

1. server - in step #5 above, redirect the user to the `exports/index` page, with the flash message described above
2. client - the page displays a new (but empty) export, with some kind of spinning Font Awesome icon next to it to show it's being worked on
3. client - XHR long-poll `exports#show` for the export, until it comes back with some sort of `{complete: true}` boolean, which I have the Resque worker set on the record when it's done, then...
4. client - refresh the page, which will then show the completed export

You can obviously make the UX of this much cleaner with, say, some client-side MVC and WebSockets, but I think this simple implementation should sufficiently serve to illustrate the basic flow.

Assuming you've worked with XHRs before, the last piece to discuss here is Resque.

## The Solution: A Resque Job

While I found [the Resque docs](https://github.com/resque/resque#overview) quite helpful, I also feel like they explain the nitty gritty of the usage more than they explain how and why to build a Resque job in the context of a specific problem, so I'm going to go ahead and duplicate some of what you can learn in the docs in my explanation below.

We'll worry about the implementation details (like Redis) and actually running this thing in a minute, but for now, let's just look at the code.

So assuming that we have Redis and Resque all wired up in our app, the next thing we want to do is create a Resque job.

The great thing about Resque jobs is that they're just Plain Old Ruby Objects, no magic, not even anything to inherit from or `include`. A Resque job is simply a Ruby module or class that:

1. responds to `perform`
2. defines the queue it watches with a module/class attribute `@@queue = :queue_name`

So here's what an implementation of a Resque job for our export problem might look like:

```ruby
### app/jobs/exporter.rb ###

module Exporter
  @@queue = :exports

  def self.perform(export_id)
    export = Export.find account_id     # fetch the empty export from the DB
    export.perform_lengthy_computation! # perform the lengthy export
  end
end
```

A couple stylistic things to note:

* `Exporter` could just as easily be a class here, but I don't like to make something a class if it's not getting instantiated. And since this object (`Exporter`) need only respond to `perform`, it deserves to be a module in my book.
* In the Resque docs, they write the `@@queue` above as `@queue`. Since it's written where it is inside the module definition, this is syntactically equivalent, but since I typically prefer to make things as explicit and unambiguous as possible, I went the extra mile and typed the extra keystroke.
* I chose `app/jobs/exporter.rb`, but you could put this anywhere you like.

As for this implementation, a couple things stand out to me:

1. `Exporter` doesn't really *do* much of anything. It's actually quite akin to a controller action: an ID comes in, it fetches the resource from the DB, and then does something with it. This is exactly how we want this to look, and I'll explain why in a minute.
2. `Exporter` doesn't really know or care about the computation here. It *could* know the details of what it takes to perform an export, but having that live inside of `Export#perform_length_computation!` would make more sense to me here, in an SRP-kind-of-way; `Exporter` exists mostly exists to watch the queue and kick off the export process when it needed.
3. The argument coming in to `perform` is an ID, *not* an `Export` instance/record. This is hugely important, because when a job in enqueued in Resque, it's [persisted as JSON](https://github.com/resque/resque#persistence). And since anything we enqueue as an argument will need to be serialized to and deserialized from JSON in the course of processing the job, we'll want to keep these arguments as simple as possible. Passing IDs in the same way that you'd make a request to a controller action (as discussed above) is an excellent way to accomplish this.

So now that we have our job, we'll need to start pushing exports onto its queue from our controller. If you refer back to our flow above, you'll see that we want to do that from `exports#create`, and that will look something like this:

```ruby
### app/controllers/exports_controller.rb ###

class ExportsController < ApplicationController
  def create
    # this creates the record, but doesn't perform the
    # lengthy computation that we want to avoid here
    export = Export.create export_params

    # place `export`'s id on the queue for `Exporter`
    Resque.enqueue Exporter, export.id

    # redirect to list of exports, with the view
    # rendering `export` with a spinner
    redirect_to 'exports#index',
      notice: 'Your export is being created, please wait.'
  end
end
```

Here we see that we enqueue things with:

```ruby
Resque.enqueue ResqueJobModuleOrClass, arg1, arg2
```

Which, [according to the docs](https://github.com/resque/resque#persistence), gets serialized to Redis as JSON like:

```
{
  "class": "ResqueJobModuleOrClass",
  "args": [ 'arg1val', 'arg2val' ]
}
```

And with that, we've completed the definition and use of our Resque job, but we still need to run it. To do this, we'll need to be sure to have a Resque *worker* running, to process the queue.

Here's the distinction:

* Resque job - the module/class that defines the work to be done
* Resque worker - the running process that monitors the queue, and sends `perform` to a Resque job

This is very similar to what we see in the world of web requests in Rails:

* we define a controller action (a class and method that defines the work to be done)
* we run a process (`rails server`) to appropriately call that method

So to this point, we've seen our analog to our controller action (the Resque job), let's take a look at the equivalent `$ rails server` call for starting a Resque worker:

```
$ QUEUE=* rake resque:work

### OR ###

$ QUEUE=exports rake resque:work
```

The first of these calls will start a Resque worker that will processes jobs on *all* queues, whereas the second will start a worker that only processes the `exports` queue, which corresponds to our `@@queue = :exports` above in our `Exporter` job.

Besides that, the `resque:work` Rake task comes with Resque, so we won't need to define that. But we have one problem yet: this Rake task knows nothing about our Rails app, which means that it won't know anything about `Export` or `Exporter`.

According to [the docs](https://github.com/resque/resque#workers), you can rectify this by defining a `resque:setup` Rake task, or more simply by starting the worker instead with:

```
$ QUEUE=* rake environment resque:work

# note the `environment` after `rake` above
```

And that does it for the implementation!


### Cleanup

That said, there's one bit above that I left in for clarity on how Resque works, that I'd probably change for production.

Here's our `exports#create` as we left it:

```ruby
### app/controllers/exports_controller.rb ###

class ExportsController < ApplicationController
  def create
    export = Export.create export_params

    Resque.enqueue Exporter, export.id

    redirect_to 'exports#index',
      notice: 'Your export is being created, please wait.'
  end
end
```

And here's closer to what I'd probably do:

```ruby
### app/models/export.rb ###
class Export < ActiveRecord::Base
  # ...

  def async_populate!
    Resque.enqueue Exporter, id
  end
end

### app/controllers/exports_controller.rb ###
class ExportsController < ApplicationController
  def create
    Export.create(export_params).async_populate!

    redirect_to 'exports#index',
      notice: 'Your export is being created, please wait.'
  end
end
```

The benefit of this approach is that it better describes what's happening in a general sense, and leaves Resque as an implementation detail, hidden inside of `Export#async_populate!`, and one that the controller action never needs to know about.

Furthermore, I didn't even name the instance method something like `#enqueue_for_population!`, because we really don't even care that it's being enqueued, only that it's being performed asynchronously. If we change the implementation of this from Resque to some other approach later, and don't even end up enqueuing things anymore, we won't need to change the name of our `Export` instance method above *or* the call to it from `exports#create`.

(I'd probably also wrap the `Export.create...` stuff in a service object, but that's beside the point, and a discussion for another day!)

### Other Quick Notes

#### Inline Jobs

Sometimes you may want to just [process Resque jobs inline](https://github.com/resque/resque#configuration). You can accomplish this with the config:

```ruby
Resque.inline = ENV['RAILS_ENV'] == "cucumber"
```

This is useful anytime you, say, don't really expect requests to timeout (e.g. when running in a test env with a small dataset), or maybe you just don't want to bother installing and starting Redis on your dev machine.

### Resque Web Front-End

Resque also ships with a convenient [web front-end for viewing pending, working, and failed jobs](https://github.com/resque/resque#the-front-end) that's worth checking out. It appears to be something of a separate Sinatra app now, but I know it used to be able to be mounted as a route on your Rails application as well.


## Setup

Well, with the fun stuff out of the way, we have to make Resque actually work.

### Redis

First, we need to make sure Redis is installed and running.

If you're on a Debian Linux distro like me, this should do the trick for the install (and I think it starts the server as well):

```
$ sudo apt-get install redis-server
```

On OS X, it looks like you can do:

```
$ brew install redis
```

Either way, make sure you have `redis-server` running:

```
$ ps -e | grep redis-server
 1950 ?        00:01:04 redis-server
```

Or fire it up with:

```
$ redis-server

...

[15729] 01 Sep 21:23:47.930 * The server is now ready to accept connections on port 6379
```

You can also just configure `redis-server` to run on system boot, but since that varies by OS, I'll leave that for you to research on your own.


### Foreman

Now, assuming that we have `redis-server` running somewhere, as things stand now, we still need to open two terminals and fire up both our Rails and Resque worker. This is a bit of a hassle.

Furthermore, if we push our app to a service like Heroku, it will see it's a Rails app and boot it appropriately, but it will be completely ignorant of even the existance of our need for a Resque worker.

To fix both of these problems in one fell swoop, let's define a `Procfile` (think "processes file") for our *whole* application, meaning both our Rails app *and* the Resque worker.

Here's [Heroku's recommended `Procfile`](https://devcenter.heroku.com/articles/getting-started-with-rails5#procfile) for a Rails 5 app served by Puma:

```
### Procfile ###

web: bundle exec puma -t 5:5 -p ${PORT:-3000} -e ${RACK_ENV:-development}
```

Here `web: ` defines a `web` process type, and the rest of the line is the command that is called to start the process.

From there, `bundle exec` makes sure we're executing in the context of our bundle, and `puma` is the command ultimately being run. The `-t` flag seems to set the `min:max` threads, `-p` the port (uses `$PORT` or default of `3000`), and `-e` the environment (`$RACK_ENV` or default `development`).

We can see something similar in `config/puma.rb`, which we're opting to no longer use here with the Procfile, but we could alternatively configure these there instead, then run `$ ... puma -C config/puma.rb` for the same result.

To start this up, we can run our `web` process from our `Procfile` using `foreman`:

```
$ foreman start web
21:46:06 web.1  | started with pid 17493
21:46:07 web.1  | Puma starting in single mode...
21:46:07 web.1  | * Version 3.6.0 (ruby 2.3.1-p112), codename: Sleepy Sunday Serenity
21:46:07 web.1  | * Min threads: 5, max threads: 5
21:46:07 web.1  | * Environment: development
21:46:08 web.1  | * Listening on tcp://0.0.0.0:5000
21:46:08 web.1  | Use Ctrl-C to stop
```

And we've got our Rails server back up and running, but using `foreman` instead now instead of `rails server`.

Two things I noted:

1. logging doesn't seem to work now
2. it's defaulting to port `5000` instead of `3000`

Not really sure why this is happening for me, but I'm going to bet on it being a case of PEBKAC.

At any rate, with the `web` process now in place, let's define our Resque worker process, once again using [a Heroku suggested `Procfile`](https://devcenter.heroku.com/articles/queuing-ruby-resque#define-and-provision-workers)

```
### Procfile ###

web: bundle exec puma -t 5:5 -p ${PORT:-3000} -e ${RACK_ENV:-development}
resque: env TERM_CHILD=1 QUEUE=exports bundle exec rake environment resque:work
```

Note: I bascially copied the suggested command, but used our `rake environment resque:work` from above, rather than the suggested `rake resque:work`, and also set `QUEUE=exports` to specify the single queue for this worker to watch.

Honestly not entirely sure what purpose the `env` call serves here, but I'd guess it has something to do with the env vars we're setting inline.

And the `TERM_CHILD` env var is something we apparently want, [according to the Heroku docs](https://devcenter.heroku.com/articles/queuing-ruby-resque#process-options):

> To opt-in to UNIX compatible signal handling in Resque v1.22 you will also need to provide a `TERM_CHILD` environment variable to the resque worker process.

Then, in addition to bundling Resque, I had to adjust the `Rakefile` to make it aware of the Resque-provided Rake tasks:

```ruby
### Rakefile ###

require_relative 'config/application'
require 'resque/tasks' # <-- my addition

Rails.application.load_tasks
```

With that, we can launch our entire application (Rails `web` worker and Resque worker) with a single command:

```
$ foreman start
22:11:51 web.1    | started with pid 19958
22:11:51 resque.1 | started with pid 19959
22:11:52 web.1    | Puma starting in single mode...
22:11:52 web.1    | * Version 3.6.0 (ruby 2.3.1-p112), codename: Sleepy Sunday Serenity
22:11:52 web.1    | * Min threads: 5, max threads: 5
22:11:52 web.1    | * Environment: development
22:11:53 web.1    | * Listening on tcp://0.0.0.0:5000
22:11:53 web.1    | Use Ctrl-C to stop
```

Notice the first two lines of output:

```
22:11:51 web.1    | started with pid 19958
22:11:51 resque.1 | started with pid 19959
```

We now have two process running, a `web` worker (the Rails app) and a `resque` worker!

On Heroku, if we scaled these dynos (processes) up, we may see additional processes listed as well, in the format:

```
22:11:51 web.1    | started with pid 19958
22:11:51 web.2    | started with pid 19959
22:11:51 web.3    | started with pid 19960
22:11:51 resque.1 | started with pid 19961
22:11:51 resque.2 | started with pid 19962
```

## Over-review

I wrote this in hopes that you'd come away better understanding the need for and purpose of Resque in a Rails application, but the path we took above, while hopefully helpful for understanding, was not the most useful for making these changes step-by-step yourself. So let's quickly go over the basic pieces, in a more coherent-to-implement order.

### Install and Setup

```ruby
### Gemfile ###

# ...

gem 'resque'
```

```
$ bundle install
```

```ruby
### Rakefile ###

require_relative 'config/application'

require 'resque/tasks' # <-- !!! ADD THIS !!!

Rails.application.load_tasks
```

```
# ensure `redis-server` is running
$ ps -e | grep redis-server

# install directions above if needed
```


### Resque Job

```ruby
### app/jobs/exporter.rb ###

module Exporter
  @@queue = :exports

  def self.perform(export_id)
    export = Export.find account_id     # fetch the empty export from the DB
    export.perform_lengthy_computation! # perform the lengthy export
  end
end
```

### App Logic

```ruby
### app/models/export.rb ###

class Export < ActiveRecord::Base
  # ...

  # do the work later
  def async_populate!
    # resque enqueuing
    Resque.enqueue Exporter, id
  end

  # the actual work
  def perform_length_computation!
    # ...
  end
end
```

```ruby
### app/controllers/exports_controller.rb ###

class ExportsController < ApplicationController
  def create
    # kick off async processing
    Export.create(export_params).async_populate!

    redirect_to 'exports#index',
      notice: 'Your export is being created, please wait.'
  end
end
```


### Resque Worker (`Procfile` / `foreman`)

```
### Procfile ###

web: bundle exec puma -t 5:5 -p ${PORT:-3000} -e ${RACK_ENV:-development}
resque: env TERM_CHILD=1 QUEUE=exports bundle exec rake environment resque:work
```

```
# fire it up!

$ foreman start
22:11:51 web.1    | started with pid 19958
22:11:51 resque.1 | started with pid 19959
22:11:52 web.1    | Puma starting in single mode...
22:11:52 web.1    | * Version 3.6.0 (ruby 2.3.1-p112), codename: Sleepy Sunday Serenity
22:11:52 web.1    | * Min threads: 5, max threads: 5
22:11:52 web.1    | * Environment: development
22:11:53 web.1    | * Listening on tcp://0.0.0.0:5000
22:11:53 web.1    | Use Ctrl-C to stop
```

And that about covers it!

I've also set up a couple branches in this repo to play with the problems hands-on.


## Getting Set Up

```
$ git clone https://github.com/bchase/resque-rails-demo.git
$ cd resque-rails-demo
$ bundle install
$ rake db:create
```

## Running The Problem
## Running The Solution


















tk - i use this to simulate https://github.com/heroku/rack-timeout

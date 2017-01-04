defmodule Apns.Mixfile do
  use Mix.Project

  def project do
    [app: :apns,
     version: "0.1.0",
     elixir: "~> 1.3",
     deps: deps,
  ]
  end

  def application do
    [

    applications: [
    # :goldrush,
    # :lager, 
    :crypto,
    :inets,
     :ssl,
     :jiffy
     # :poolboy
     ] ,
 # erl_opts: [parse_transform: "lager_transform"],
     mod: {:apns, []}
   ]
  end

  defp deps do
    [
       # {:lager, git: "git://github.com/basho/lager.git", branch: "master",  override: true},
       # {:telegram_db, git: "git@192.168.212.220:developerworks/telegram_db.git", branch: "develop"},
       # {:poolboy, "~> 1.5"},
       {:jiffy,  git: "git://github.com/davisp/jiffy.git", tag: "0.14.11"}
    ]
  end
end

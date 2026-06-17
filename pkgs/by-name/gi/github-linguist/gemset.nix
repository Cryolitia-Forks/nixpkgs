{
  addressable = {
    dependencies = ["public_suffix"];
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1by7h2lwziiblizpd5yx87jsq8ppdhzvwf08ga34wzqgcv1nmpvz";
      type = "gem";
    };
    version = "2.9.0";
  };
  byebug = {
    dependencies = ["reline"];
    groups = ["debug"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0pg05blj56sxdxq9d54386y9rlvj36vl95x21x9clh8rfpz3w9nj";
      type = "gem";
    };
    version = "13.0.0";
  };
  cgi = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1s8qdw1nfh3njd47q154njlfyc2llcgi4ik13vz39adqd7yclgz9";
      type = "gem";
    };
    version = "0.5.1";
  };
  charlock_holmes = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1c1dws56r7p8y363dhyikg7205z59a3bn4amnv2y488rrq8qm7ml";
      type = "gem";
    };
    version = "0.7.9";
  };
  coderay = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0jvxqxzply1lwp7ysn94zjhh57vc14mcshw1ygw14ib8lhc00lyw";
      type = "gem";
    };
    version = "1.1.3";
  };
  csv = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0gz7r2kazwwwyrwi95hbnhy54kwkfac5swh2gy5p5vw36fn38lbf";
      type = "gem";
    };
    version = "3.3.5";
  };
  dotenv = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "17b1zr9kih0i3wb7h4yq9i8vi6hjfq07857j437a8z7a44qvhxg3";
      type = "gem";
    };
    version = "3.2.0";
  };
  faraday = {
    dependencies = ["faraday-net_http" "json" "logger"];
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0y7j6yzv07zggic6g0p2v1ivnvkzsbqjnfdl4215qqb6cxz290hq";
      type = "gem";
    };
    version = "2.14.3";
  };
  faraday-net_http = {
    dependencies = ["net-http"];
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "125m3qri52vwh5v9dhq0dkqxf8629cxrf99yyc01pva72wasyy0f";
      type = "gem";
    };
    version = "3.4.4";
  };
  github-linguist = {
    dependencies = ["cgi" "charlock_holmes" "mini_mime" "rugged"];
    groups = ["default"];
    platforms = [];
    source = {
      path = ./.;
      type = "path";
    };
    version = "9.6.0";
  };
  io-console = {
    groups = ["debug" "default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1k0lk3pwadm2myvpg893n8jshmrf2sigrd4ki15lymy7gixaxqyn";
      type = "gem";
    };
    version = "0.8.2";
  };
  json = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "16mp8vzgxa8nsa81np042za453j8b0ihpjkf666s7byxrnvjb44v";
      type = "gem";
    };
    version = "2.19.9";
  };
  licensed = {
    dependencies = ["csv" "json" "licensee" "ostruct" "parallel" "pathname-common_prefix" "reverse_markdown" "ruby-xxHash" "thor" "tomlrb"];
    groups = ["development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "05y0hrq18x7fzpfgbapn0c8v1d3ky8ajfi8wq4jiw4bym2b9k0gh";
      type = "gem";
    };
    version = "5.1.0";
  };
  licensee = {
    dependencies = ["dotenv" "octokit" "reverse_markdown" "rugged" "thor"];
    groups = ["development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "12n2s6z2fry9q89j9qcjdy59c14k0qbkvwwhkp4m62wkw6hp282i";
      type = "gem";
    };
    version = "9.20.0";
  };
  logger = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "00q2zznygpbls8asz5knjvvj2brr3ghmqxgr83xnrdj4rk3xwvhr";
      type = "gem";
    };
    version = "1.7.0";
  };
  method_source = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1igmc3sq9ay90f8xjvfnswd1dybj1s3fi0dwd53inwsvqk4h24qq";
      type = "gem";
    };
    version = "1.1.0";
  };
  mini_mime = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1vycif7pjzkr29mfk4dlqv3disc5dn0va04lkwajlpr1wkibg0c6";
      type = "gem";
    };
    version = "1.1.5";
  };
  mini_portile2 = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "12f2830x7pq3kj0v8nz0zjvaw02sv01bqs1zwdrc04704kwcgmqc";
      type = "gem";
    };
    version = "2.8.9";
  };
  minitest = {
    groups = ["development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1mbpz92ml19rcxxfjrj91gmkif9khb1xpzyw38f81rvglgw1ffrd";
      type = "gem";
    };
    version = "5.27.0";
  };
  mocha = {
    dependencies = ["ruby2_keywords"];
    groups = ["development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1vjfizp8yq0319dkc8yzzxr2bv5f1ki1qiknyx72prs7vclyfxqz";
      type = "gem";
    };
    version = "2.8.2";
  };
  net-http = {
    dependencies = ["uri"];
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "15k96fj6qwbaiv6g52l538ass95ds1qwgynqdridz29yqrkhpfi5";
      type = "gem";
    };
    version = "0.9.1";
  };
  nokogiri = {
    dependencies = ["mini_portile2" "racc"];
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "17c3s645l3x9cjrr8srnjz0s3p4ccdvj35aim61d1j9kzm87xp5w";
      type = "gem";
    };
    version = "1.19.3";
  };
  octokit = {
    dependencies = ["faraday" "sawyer"];
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1s14kbjfm9vdvcrwqdarfdbfsjqs1jxpglp60plvfdvnkd9rmsc2";
      type = "gem";
    };
    version = "10.0.0";
  };
  ostruct = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "04nrir9wdpc4izqwqbysxyly8y7hsfr4fsv69rw91lfi9d5fv8lm";
      type = "gem";
    };
    version = "0.6.3";
  };
  parallel = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0w697335hi5dk5ay9kyn53399sy87y8v0y6ij93m5wmshhadxrik";
      type = "gem";
    };
    version = "1.28.0";
  };
  pathname-common_prefix = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "034gjbcqrf940199k28kfqbs4dwwf4slah7l9qj0n9wk4vj8bjfk";
      type = "gem";
    };
    version = "0.0.2";
  };
  plist = {
    groups = ["development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0hlaf4b3d8grxm9fqbnam5gwd55wvghl0jyzjd1hc5hirhklaynk";
      type = "gem";
    };
    version = "3.7.2";
  };
  pry = {
    dependencies = ["coderay" "method_source" "reline"];
    groups = ["development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0kh5nv8v74k1ccy6gc7nd04aaf1cjkbk7g8pwy2izvcqaq36jv6p";
      type = "gem";
    };
    version = "0.16.0";
  };
  public_suffix = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "08znfv30pxmdkjyihvbjqbvv874dj3nybmmyscl958dy3f7v12qs";
      type = "gem";
    };
    version = "7.0.5";
  };
  racc = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0byn0c9nkahsl93y9ln5bysq4j31q8xkf2ws42swighxd4lnjzsa";
      type = "gem";
    };
    version = "1.8.1";
  };
  rake = {
    groups = ["development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "009p524zl0p0kfa65nii8wdmaigkmawv9pbvlcffky7islmmp0nb";
      type = "gem";
    };
    version = "13.4.2";
  };
  rake-compiler = {
    dependencies = ["rake"];
    groups = ["development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1j166viy5491wawqn49fdaazwwrmkrr85c90qq92z3sdyzn8y9sa";
      type = "gem";
    };
    version = "0.9.9";
  };
  reline = {
    dependencies = ["io-console"];
    groups = ["debug" "default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0d8q5c4nh2g9pp758kizh8sfrvngynrjlm0i1zn3cnsnfd4v160i";
      type = "gem";
    };
    version = "0.6.3";
  };
  reverse_markdown = {
    dependencies = ["nokogiri"];
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1bxqlpwnixn8x4bnna958w6m6qkdkbnd23b9j6ib3nrrrs9bp3l1";
      type = "gem";
    };
    version = "3.0.2";
  };
  ruby-xxHash = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1106y8dvfsrvg7ph4kagbzsd2pbm4fsggv7amcrbrl0vxh2q6790";
      type = "gem";
    };
    version = "0.4.0.2";
  };
  ruby2_keywords = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1vz322p8n39hz3b4a9gkmz9y7a5jaz41zrm2ywf31dvkqm03glgz";
      type = "gem";
    };
    version = "0.0.5";
  };
  rugged = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1b7gcf6pxg4x607bica68dbz22b4kch33yi0ils6x3c8ql9akakz";
      type = "gem";
    };
    version = "1.9.0";
  };
  sawyer = {
    dependencies = ["addressable" "faraday"];
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0hayryyz46nlkcb6j0ij0kxq6i3ryiigwfc6ccvp0108hhlij3qd";
      type = "gem";
    };
    version = "0.9.3";
  };
  thor = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0wsy88vg2mazl039392hqrcwvs5nb9kq8jhhrrclir2px1gybag3";
      type = "gem";
    };
    version = "1.5.0";
  };
  tomlrb = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "168v339gqaly00i4zqg2ag2h10r3rl7999d0cqrrpb63gaa7fbr6";
      type = "gem";
    };
    version = "2.0.4";
  };
  uri = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1ijpbj7mdrq7rhpq2kb51yykhrs2s54wfs6sm9z3icgz4y6sb7rp";
      type = "gem";
    };
    version = "1.1.1";
  };
  yajl-ruby = {
    groups = ["development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1lni4jbyrlph7sz8y49q84pb0sbj82lgwvnjnsiv01xf26f4v5wc";
      type = "gem";
    };
    version = "1.4.3";
  };
}

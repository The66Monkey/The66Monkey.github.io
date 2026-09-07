---
layout: page
title: Linux Gaming
permalink: /linux-gaming/
---

A running list of posts about gaming on Linux — what works, what's a trash fire, and everything in between.

<ul class="post-list">
  {%- for post in site.categories['linux-gaming'] -%}
  <li>
    <span class="post-meta">{{ post.date | date: "%b %-d, %Y" }}</span>
    <h3>
      <a class="post-link" href="{{ post.url | relative_url }}">
        {{ post.title | escape }}
      </a>
    </h3>
  </li>
  {%- endfor -%}
</ul>

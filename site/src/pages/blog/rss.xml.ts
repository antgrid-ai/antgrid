import rss from "@astrojs/rss";
import { SITE_URL } from "../../config";
import { getPublishedPosts } from "../../data/blog";
import { postPath } from "../../data/blog-policy";

export async function GET() {
  return rss({
    title: "Antgrid Blog",
    description: "Notes from building agents that have to prove they're done.",
    site: SITE_URL,
    trailingSlash: false,
    items: (await getPublishedPosts()).map((post) => ({ title: post.data.title, description: post.data.description, pubDate: post.data.publishedAt, link: postPath(post) })),
  });
}

import { defineCollection, z } from "astro:content";

const chaptersSchema = z
  .array(
    z.object({
      time: z.string(),
      title: z.string(),
      img: z.string().url().optional(),
      url: z.string().url().optional(),
    })
  )
  .optional();

const episodes = defineCollection({
  type: "content",
  schema: z.object({
    episodeNumber: z.number(),
    title: z.string(),
    date: z.string(),
    summary: z.string(),
    audioUrl: z
      .string()
      .refine(
        (value) => value.startsWith("/") || /^https?:\/\//i.test(value),
        "audioUrl must be an absolute URL or a site-relative path"
      ),
    audioSize: z.number(),
    duration: z.string(),
    coverImage: z.string().optional().default("/images/podcast-cover-large.png"),
    explicit: z.boolean(),
    youtubeUrl: z.string().url().optional(),
    transcriptUrl: z.string().url().optional(),
    chapters: chaptersSchema,
    tags: z.array(z.string()).optional(),
    draft: z.boolean().optional().default(false),
    hosts: z.array(z.string()).optional(),
    guests: z
      .array(
        z.object({
          name: z.string(),
          avatar: z.string().optional(),
          link: z.string().url().optional(),
        })
      )
      .optional(),
    sponsors: z
      .array(
        z.object({
          name: z.string(),
          url: z.string().url().optional(),
          link: z.string().url().optional(),
          blurb: z.string().optional(),
        })
      )
      .optional(),
  }),
});

const hosts = defineCollection({
  type: "content",
  schema: z.object({
    name: z.string(),
    role: z.string().optional(),
    avatar: z.string().optional(),
    social: z.object({
      github: z.string().optional(),
      twitter: z.string().optional(),
      mastodon: z.string().optional(),
      website: z.string().optional(),
      linkedin: z.string().optional(),
      youtube: z.string().optional(),
    }).optional(),
    order: z.number().optional().default(999),
  }),
});

export const collections = {
  episodes,
  hosts,
};
